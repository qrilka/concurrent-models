{-# Language TemplateHaskell #-}
{-# Language RankNTypes      #-}

module Control.StateMachine.Runtime where

import           Universum
import           Data.Describe
import           Control.Loger
import           Control.Lens.At (at, Index, IxValue, At)
import           Control.Lens.TH
import           Control.StateMachine.Domain
import qualified Data.Map as M
import qualified Data.Set as S

type TransitionMap          = M.Map (MachineState, EventType) MachineState
type ConditionalTransitions = M.Map (MachineState, EventType) (MachineEvent -> IO (Maybe MachineState))
data Transition             = Transition MachineState MachineState

data StateMaschineData = StateMaschineData
    { _stateMachineStruct       :: StateMaschineStruct
    , _currentState             :: MachineState
    , _loger                    :: Loger
    , _handlers                 :: StateMaschineHandlers
    }

data StateMaschineStruct = StateMaschineStruct
    { _transitions              :: TransitionMap
    , _conditionalTransitions   :: ConditionalTransitions
    , _finishStates             :: S.Set MachineState
    }

data StateMaschineHandlers = StateMaschineHandlers
    { _staticalDo               :: M.Map (MachineState, EventType) (MachineEvent -> IO ())
    , _entryDo                  :: M.Map MachineState (IO ())
    , _entryWithEventDo         :: M.Map (MachineState, EventType) (MachineEvent -> IO ())
    , _transitionDo             :: M.Map (MachineState, EventType, MachineState) (MachineEvent -> IO ())
    , _exitWithEventDo          :: M.Map (MachineState, EventType) (MachineEvent -> IO ())
    , _exitDo                   :: M.Map MachineState (IO ())
    }

makeLenses ''StateMaschineStruct
makeLenses ''StateMaschineData
makeLenses ''StateMaschineHandlers

emptyHandlers :: StateMaschineHandlers
emptyHandlers = StateMaschineHandlers mempty mempty mempty mempty mempty mempty

emptyStruct :: StateMaschineStruct
emptyStruct = StateMaschineStruct mempty mempty mempty

emptyData :: Loger -> MachineState -> StateMaschineData
emptyData loger' initState =
    StateMaschineData emptyStruct initState loger' emptyHandlers

takeTransition :: MachineEvent -> StateMaschineData -> IO (Maybe Transition)
takeTransition event maschineData =
    case lookupByEvent transitionMap of
        Just newState -> pure . Just $ Transition currentState' newState
        Nothing       -> case lookupByEvent conditionals of
            Just condition -> do
                mNewState <- condition event
                case mNewState of
                    Just newState -> pure . Just $ Transition currentState' newState
                    Nothing       -> pure Nothing
            Nothing        -> pure Nothing
    where
        lookupByEvent :: M.Map (MachineState, EventType) a -> Maybe a 
        lookupByEvent = M.lookup (currentState', eventToType event)

        currentState' :: MachineState
        currentState'  = maschineData ^. currentState
        
        transitionMap :: TransitionMap
        transitionMap = maschineData ^. stateMachineStruct . transitions

        conditionals :: ConditionalTransitions
        conditionals = maschineData ^. stateMachineStruct . conditionalTransitions

applyTransitionActions :: StateMaschineData -> MachineState -> MachineEvent -> MachineState -> IO ()
applyTransitionActions machineData state1 event state2 = do
    applyExitDo             machineData state1
    applyExitWithEventDo    machineData state1 event
    applyTransitionDo       machineData state1 event state2
    applyEntryWithEventDo   machineData state2 event
    applyEntryDo            machineData state2

applyEntryDo :: StateMaschineData -> MachineState -> IO ()
applyEntryDo machineData st =
    whenJust (machineData ^. handlers . entryDo . at st) $ \action -> do
        machineData ^. loger $ "[entry do] " <> describe st
        action

applyExitDo :: StateMaschineData -> MachineState -> IO ()
applyExitDo machineData st =
    whenJust (machineData ^. handlers . exitDo . at st) $ \action -> do
        machineData ^. loger $ "[exit do] " <> describe st
        action

applyExitWithEventDo :: StateMaschineData -> MachineState -> MachineEvent -> IO ()
applyExitWithEventDo machineData st event =
    whenJust (machineData ^. handlers . exitWithEventDo . at2 st (eventToType event)) $ \action -> do
        machineData ^. loger $ "[exit with event do] " <> describe st <> " " <> describe event
        action event

applyEntryWithEventDo :: StateMaschineData -> MachineState -> MachineEvent -> IO ()
applyEntryWithEventDo machineData st event =
    whenJust (machineData ^. handlers . entryWithEventDo . at2 st (eventToType event)) $ \action -> do
        machineData ^. loger $ "[entry with event do] " <> describe st <> " " <> describe event
        action event

applyTransitionDo :: StateMaschineData -> MachineState -> MachineEvent -> MachineState -> IO ()
applyTransitionDo machineData st1 event st2 =
    whenJust (machineData ^. handlers . transitionDo . at3 st1 (eventToType event) st2) $ \action -> do
        machineData ^. loger $ "[entry with event do] " <> describe st1 <> " -> " <> describe event <> describe st1
        action event

applyStaticalDo :: StateMaschineData -> MachineEvent -> IO ()
applyStaticalDo machineData event = do
    let st = machineData ^. currentState
    whenJust (machineData ^. handlers . staticalDo . at2 st (eventToType event)) $ \action -> do
        machineData ^. loger $ "[statical do] " <> describe st <> describe event
        action event

isFinish :: StateMaschineData -> MachineState -> Bool
isFinish machineData currentState' =
    S.member currentState' (machineData ^. stateMachineStruct . finishStates)

at2 :: (Index m ~ (a, b), At m) => a -> b -> Lens' m (Maybe (IxValue m))
at2 x y = at (x, y)

at3 :: (Index m ~ (a, b, c), At m) => a -> b -> c -> Lens' m (Maybe (IxValue m))
at3 x y z = at (x, y, z)