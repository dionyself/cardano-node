{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StandaloneDeriving #-}

{-# OPTIONS_GHC -Wno-orphans #-}

module Cardano.Node.Tracing.StateRep
  ( AddedToCurrentChain (..)
  , InitChainSelection (..)
  , NodeState (..)
  , OpeningDbs (..)
  , Replays (..)
  , StartupState (..)
  , traceNodeStateChainDB
  , traceNodeStateStartup
  , traceNodeStateShutdown
  , namesNodeState
  , severityNodeState
  , docNodeState
  ) where

import           Cardano.Logging
import           Cardano.Prelude
import           Data.Aeson
import           Data.Time.Clock
import           Data.Time.Clock.POSIX

import           Cardano.Node.Protocol.Types (SomeConsensusProtocol (..))
import qualified Ouroboros.Consensus.Block.RealPoint as RP
import qualified Ouroboros.Consensus.Node.NetworkProtocolVersion as NPV
import qualified Ouroboros.Consensus.Storage.ChainDB as ChainDB
import           Ouroboros.Consensus.Storage.ImmutableDB.Chunks.Internal
import qualified Ouroboros.Consensus.Storage.LedgerDB.OnDisk as LgrDb
import           Ouroboros.Network.Block (pointSlot)

import           Cardano.Node.Handlers.Shutdown (ShutdownTrace)
import qualified Cardano.Node.Startup as Startup
import           Cardano.Slotting.Slot (EpochNo, SlotNo (..), WithOrigin)
import           Cardano.Tracing.OrphanInstances.Network ()

instance FromJSON ChunkNo
instance FromJSON (WithOrigin SlotNo)

instance ToJSON ChunkNo
instance ToJSON (WithOrigin SlotNo)

data OpeningDbs
  = StartedOpeningImmutableDB
  | OpenedImmutableDB (WithOrigin SlotNo) ChunkNo
  | StartedOpeningVolatileDB
  | OpenedVolatileDB
  | StartedOpeningLgrDB
  | OpenedLgrDB
  deriving (Generic, FromJSON, ToJSON)

data Replays
  = ReplayFromGenesis  (WithOrigin SlotNo)
  | ReplayFromSnapshot SlotNo (WithOrigin SlotNo) (WithOrigin SlotNo)
  | ReplayedBlock      SlotNo (WithOrigin SlotNo) (WithOrigin SlotNo)
  deriving (Generic, FromJSON, ToJSON)

data InitChainSelection
  = InitChainStartedSelection
  | InitChainSelected
  deriving (Generic, FromJSON, ToJSON)

type SyncPercentage = Double

data AddedToCurrentChain
  = AddedToCurrentChain !EpochNo !SlotNo !SyncPercentage
  deriving (Generic, FromJSON, ToJSON)

deriving instance Generic NPV.NodeToClientVersion
deriving instance Generic NPV.NodeToNodeVersion

instance FromJSON NPV.NodeToClientVersion
instance FromJSON NPV.NodeToNodeVersion

data StartupState
  = StartupSocketConfigError Text
  | StartupDBValidation
  | NetworkConfigUpdate
  | NetworkConfigUpdateError Text
  | P2PWarning
  | P2PWarningDevelopementNetworkProtocols
  | WarningDevelopmentNetworkProtocols [NPV.NodeToNodeVersion] [NPV.NodeToClientVersion]
  deriving (Generic, FromJSON, ToJSON)

-- | The representation of the current state of node.
--   All node states prior to tracing system going online are effectively invisible.
data NodeState
  = NodeTracingOnlineConfiguring
  | NodeOpeningDbs OpeningDbs
  | NodeReplays Replays
  | NodeInitChainSelection InitChainSelection
  | NodeKernelOnline
  | NodeAddBlock AddedToCurrentChain
  | NodeStartup StartupState
  | NodeShutdown ShutdownTrace
  deriving (Generic, FromJSON, ToJSON)

instance LogFormatting NodeState where
  forMachine _ = \case
    NodeOpeningDbs x -> mconcat
      [ "kind" .= String "NodeOpeningDbs",         "openingDb" .= toJSON x]
    NodeReplays x -> mconcat
      [ "kind" .= String "NodeReplays",            "replays"   .= toJSON x]
    NodeInitChainSelection x -> mconcat
      [ "kind" .= String "NodeInitChainSelection", "chainSel"  .= toJSON x]
    NodeAddBlock x -> mconcat
      [ "kind" .= String "NodeAddBlock",           "addBlock"  .= toJSON x]
    NodeStartup x -> mconcat
      [ "kind" .= String "NodeStartup",            "startup"   .= toJSON x]
    NodeShutdown x -> mconcat
      [ "kind" .= String "NodeShutdown",           "shutdown"  .= toJSON x]
    _ -> mempty

docNodeState :: Documented NodeState
docNodeState = addDocumentedNamespace  [] $
  Documented
  [ DocMsg ["NodeTracingOnlineConfiguring"] [] "Tracing system came online, system configuring now"
  , DocMsg ["NodeOpeningDbs"]               [] "ChainDB components being opened"
  , DocMsg ["NodeReplays"]                  [] "Replaying chain"
  , DocMsg ["NodeInitChainSelection"]       [] "Performing initial chain selection"
  , DocMsg ["NodeKernelOnline"]             [] "Node kernel online"
  , DocMsg ["NodeAddBlock"]                 [] "Applying block"
  , DocMsg ["NodeStartup"]                  [] "Node startup"
  , DocMsg ["NodeShutdown"]                 [] "Node shutting down"
  ]

namesNodeState :: NodeState -> [Text]
namesNodeState = \case
  NodeTracingOnlineConfiguring -> ["TracingOnlineConfiguring"]
  NodeOpeningDbs _x -> ["OpeningDbs"] -- : namesOpeninDbs x
  NodeReplays _x -> ["Replays"] -- : namesReplays x
  NodeInitChainSelection _x -> ["InitChainSelection"] -- : namesInitChainSelection -- Worth it?
  NodeKernelOnline -> ["NodeKernelOnline"]
  NodeAddBlock _x -> ["AddBlock"] -- : namesAddBlock x
  NodeStartup _x -> ["Startup"] -- : namesForStartup x -- Worth it?
  NodeShutdown _x -> ["Shutdown"] -- : namesShutdown x

severityNodeState :: NodeState -> SeverityS
severityNodeState = \case
  NodeTracingOnlineConfiguring -> Info
  NodeOpeningDbs _x -> Info
  NodeReplays _x -> Notice
  NodeInitChainSelection _x -> Notice
  NodeKernelOnline -> Info
  NodeAddBlock _x -> Notice
  NodeStartup _x -> Info
  NodeShutdown _x -> Warning

traceNodeStateChainDB
  :: SomeConsensusProtocol
  -> Trace IO NodeState
  -> ChainDB.TraceEvent blk
  -> IO ()
traceNodeStateChainDB _scp tr ev =
  case ev of
    ChainDB.TraceOpenEvent ev' ->
      case ev' of
        ChainDB.StartedOpeningImmutableDB ->
          traceWith tr $ NodeOpeningDbs StartedOpeningImmutableDB
        ChainDB.OpenedImmutableDB p chunk ->
          traceWith tr $ NodeOpeningDbs $ OpenedImmutableDB (pointSlot p) chunk
        ChainDB.StartedOpeningVolatileDB ->
          traceWith tr $ NodeOpeningDbs StartedOpeningVolatileDB
        ChainDB.OpenedVolatileDB ->
          traceWith tr $ NodeOpeningDbs OpenedVolatileDB
        ChainDB.StartedOpeningLgrDB ->
          traceWith tr $ NodeOpeningDbs StartedOpeningLgrDB
        ChainDB.OpenedLgrDB ->
          traceWith tr $ NodeOpeningDbs OpenedLgrDB
        _ -> return ()
    ChainDB.TraceLedgerReplayEvent ev' ->
      case ev' of
        LgrDb.ReplayFromGenesis (LgrDb.ReplayGoal p) ->
          traceWith tr $ NodeReplays $ ReplayFromGenesis (pointSlot p)
        LgrDb.ReplayFromSnapshot _ (RP.RealPoint s _) (LgrDb.ReplayStart rs) (LgrDb.ReplayGoal rp) ->
          traceWith tr $ NodeReplays $ ReplayFromSnapshot s (pointSlot rs) (pointSlot rp)
        LgrDb.ReplayedBlock (RP.RealPoint s _) _ (LgrDb.ReplayStart rs) (LgrDb.ReplayGoal rp) ->
          traceWith tr $ NodeReplays $ ReplayedBlock s (pointSlot rs) (pointSlot rp)
    ChainDB.TraceInitChainSelEvent ev' ->
      case ev' of
        ChainDB.StartedInitChainSelection ->
          traceWith tr $ NodeInitChainSelection InitChainStartedSelection
        ChainDB.InitalChainSelected ->
          traceWith tr $ NodeInitChainSelection InitChainSelected
        _ -> return ()
    ChainDB.TraceAddBlockEvent ev' ->
      case ev' of
        ChainDB.AddedToCurrentChain _ (ChainDB.NewTipInfo currentTip ntEpoch sInEpoch _) _ _ -> do
          -- The slot of the latest block consumed (our progress).
          let RP.RealPoint ourSlotSinceSystemStart _ = currentTip
          -- The slot corresponding to the latest wall-clock time (our target).
          slotSinceSystemStart <- getSlotForNow
          let syncProgressPct :: SyncPercentage
              syncProgressPct = (   fromIntegral (unSlotNo ourSlotSinceSystemStart)
                                  / fromIntegral (unSlotNo slotSinceSystemStart)
                                ) * 100.0
          traceWith tr $ NodeAddBlock $
            AddedToCurrentChain ntEpoch (SlotNo sInEpoch) syncProgressPct
        _ -> return ()
    _ -> return ()

traceNodeStateStartup
  :: Trace IO NodeState
  -> Startup.StartupTrace blk
  -> IO ()
traceNodeStateStartup tr ev =
  case ev of
    Startup.StartupSocketConfigError e ->
      traceWith tr $ NodeStartup $ StartupSocketConfigError (show e)
    Startup.StartupDBValidation ->
      traceWith tr $ NodeStartup StartupDBValidation
    Startup.NetworkConfigUpdate ->
      traceWith tr $ NodeStartup NetworkConfigUpdate
    Startup.NetworkConfigUpdateError e ->
      traceWith tr $ NodeStartup $ NetworkConfigUpdateError e
    Startup.P2PWarning ->
      traceWith tr $ NodeStartup P2PWarning
    Startup.P2PWarningDevelopementNetworkProtocols ->
      traceWith tr $ NodeStartup P2PWarningDevelopementNetworkProtocols
    Startup.WarningDevelopmentNetworkProtocols n2ns n2cs ->
      traceWith tr $ NodeStartup $ WarningDevelopmentNetworkProtocols n2ns n2cs
    _ -> return ()

traceNodeStateShutdown
  :: Trace IO NodeState
  -> ShutdownTrace
  -> IO ()
traceNodeStateShutdown tr = traceWith tr . NodeShutdown

-- Misc.

getSlotForNow :: IO SlotNo
getSlotForNow = do
  posixNow <- utc2s <$> getCurrentTime
  -- Since Shelley era the slot length is 1 second, so the number of seconds is the number of slots.
  let numberOfSlotsFromShelleyTillNow = posixNow - posixStartOfShelleyEra
      totalNumberOfSlotsTillNow = numberOfSlotsInByronEra + numberOfSlotsFromShelleyTillNow
  return $ SlotNo totalNumberOfSlotsTillNow
 where
  -- These numbers are taken from 'First-Block-of-Each-Era' wiki page.
  posixStartOfShelleyEra = 1596073491
  numberOfSlotsInByronEra = 4492799
  utc2s = fromInteger . round . utcTimeToPOSIXSeconds
