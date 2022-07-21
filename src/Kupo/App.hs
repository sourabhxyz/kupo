--  This Source Code Form is subject to the terms of the Mozilla Public
--  License, v. 2.0. If a copy of the MPL was not distributed with this
--  file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE RecordWildCards #-}

module Kupo.App
    ( -- * Producer
      ChainSyncClient
    , newProducer

      -- * Consumer
    , consumer

      -- * Gardener
    , gardener

      -- * Internal
    , mailboxSize
    ) where

import Kupo.Prelude

import Control.Monad.Class.MonadTimer
    ( MonadDelay (..) )
import Kupo.App.ChainSync
    ( TraceChainSync (..) )
import Kupo.App.Configuration
    ( TraceConfiguration (..), parseNetworkParameters )
import Kupo.App.Database
    ( DBTransaction, Database (..), TraceDatabase (..) )
import Kupo.App.Mailbox
    ( Mailbox, flushMailbox, newMailbox )
import Kupo.Control.MonadCatch
    ( MonadCatch (..) )
import Kupo.Control.MonadLog
    ( MonadLog (..), Tracer )
import Kupo.Control.MonadOuroboros
    ( MonadOuroboros (..), NodeToClientVersion (..) )
import Kupo.Control.MonadSTM
    ( MonadSTM (..) )
import Kupo.Control.MonadThrow
    ( MonadThrow (..) )
import Kupo.Data.Cardano
    ( Block
    , IsBlock
    , Point
    , SlotNo (..)
    , Tip
    , distanceToTip
    , getPoint
    , getPointSlotNo
    )
import Kupo.Data.ChainSync
    ( IntersectionNotFoundException (..) )
import Kupo.Data.Configuration
    ( ChainProducer (..)
    , Configuration (..)
    , InputManagement (..)
    , LongestRollback (..)
    , NetworkParameters (..)
    )
import Kupo.Data.Database
    ( binaryDataToRow, pointToRow, resultToRow )
import Kupo.Data.Pattern
    ( Codecs (..), Pattern, matchBlock )

import qualified Data.Map as Map
import qualified Kupo.App.ChainSync.Direct as Direct
import qualified Kupo.App.ChainSync.Ogmios as Ogmios

--
-- Producer
--

type ChainSyncClient m block =
       Tracer IO TraceChainSync
    -> [Point Block] -- Checkpoints
    -> ConnectionStatusToggle m
    -> m ()

newProducer
    :: Tracer IO TraceConfiguration
    -> ChainProducer
    -> ( forall block. IsBlock block
        => Mailbox IO (Tip Block, block) (Tip Block, Point Block)
        -> ChainSyncClient IO block
        -> IO ()
       )
    -> IO ()
newProducer tracerConfiguration chainProducer callback = do
    case chainProducer of
        Ogmios{ogmiosHost, ogmiosPort} -> do
            logWith tracerConfiguration ConfigurationOgmios{ogmiosHost, ogmiosPort}
            mailbox <- atomically (newMailbox mailboxSize)
            callback mailbox $ \_tr checkpoints statusToggle -> do
                Ogmios.connect statusToggle ogmiosHost ogmiosPort $
                    Ogmios.runChainSyncClient mailbox checkpoints

        CardanoNode{nodeSocket, nodeConfig} -> do
            logWith tracerConfiguration ConfigurationCardanoNode{nodeSocket,nodeConfig}
            mailbox <- atomically (newMailbox mailboxSize)
            network@NetworkParameters
                { networkMagic
                , slotsPerEpoch
                } <- liftIO (parseNetworkParameters nodeConfig)
            logWith tracerConfiguration (ConfigurationNetwork network)
            callback mailbox $ \tracerChainSync checkpoints statusToggle -> do
                withChainSyncServer
                  statusToggle
                  [ NodeToClientV_9 .. maxBound ]
                  networkMagic
                  slotsPerEpoch
                  nodeSocket
                  (Direct.mkChainSyncClient mailbox checkpoints)
                  & handle (\e@IntersectionNotFound{requestedPoints = points} -> do
                      logWith tracerChainSync ChainSyncIntersectionNotFound{points}
                      throwIO e
                    )

-- TODO: Make the mailbox's size configurable? Larger sizes means larger
-- memory usage at the benefits of slightly faster sync time... Though I
-- am not sure it's worth enough to bother users with this. Between 100
-- and 1000, the heap increases from ~150MB to ~1GB, for a 5-10%
-- synchronization time decrease.
mailboxSize :: Natural
mailboxSize = 100

-- | Consumer process that is reading messages from the 'Mailbox'. Messages are
-- enqueued by another process (the producer).
consumer
    :: forall m block.
        ( MonadSTM m
        , MonadLog m
        , Monad (DBTransaction m)
        , IsBlock block
        )
    => Tracer IO TraceChainSync
    -> InputManagement
    -> LongestRollback
    -> (Tip Block -> Maybe SlotNo -> DBTransaction m ())
    -> Mailbox m (Tip Block, block) (Tip Block, Point Block)
    -> TVar m [Pattern]
    -> Database m
    -> m Void
consumer tr inputManagement longestRollback notifyTip mailbox patternsVar Database{..} =
    forever $ do
        atomically ((,) <$> flushMailbox mailbox <*> readTVar patternsVar) >>= \case
            (Left blks, patterns) ->
                rollForward blks patterns
            (Right pt, _) ->
                rollBackward pt
  where
    rollForward :: (NonEmpty (Tip Block, block) -> [Pattern] -> m ())
    rollForward blks patterns = do
        let (lastKnownTip, lastKnownBlk) = last blks
        let lastKnownPoint = getPoint lastKnownBlk
        let lastKnownSlot = getPointSlotNo lastKnownPoint
        let (spentInputs, newInputs, bins) = foldMap (matchBlock codecs patterns . snd) blks
        logWith tr (ChainSyncRollForward lastKnownSlot (length newInputs))
        runReadWriteTransaction $ do
            insertCheckpoints (foldr ((:) . pointToRow . getPoint . snd) [] blks)
            insertInputs newInputs
            onSpentInputs lastKnownTip lastKnownSlot spentInputs
            insertBinaryData bins
            notifyTip lastKnownTip (Just lastKnownSlot)

    rollBackward :: (Tip Block, Point Block) -> m ()
    rollBackward (tip, pt) = do
        logWith tr (ChainSyncRollBackward (getPointSlotNo pt))
        runReadWriteTransaction $ do
            lastKnownSlot <- rollbackTo (unSlotNo (getPointSlotNo pt))
            notifyTip tip (SlotNo <$> lastKnownSlot)

    codecs = Codecs
        { toResult = resultToRow
        , toSlotNo = unSlotNo
        , toInput = serialize'
        , toBinaryData = binaryDataToRow
        }

    onSpentInputs = case inputManagement of
        MarkSpentInputs ->
            \_ _ -> void . Map.traverseWithKey markInputsByReference
        RemoveSpentInputs ->
            \lastKnownTip lastKnownSlot ->
                -- Only delete when safe (i.e. deep enough in the chain).
                -- Otherwise, mark as 'spent' and leave the pruning to the
                -- periodic 'gardener' / garbage-collector.
                if distanceToTip lastKnownTip lastKnownSlot > unstableWindow then
                    traverse_ deleteInputsByReference
                else
                    void . Map.traverseWithKey markInputsByReference
      where
        unstableWindow =
            getLongestRollback longestRollback

-- | Periodically garbage collect the database from entries that aren't of
-- interest. This is mainly the case for:
--
-- - spent inputs that are _definitely spent_
-- - binary data stored in the database that isn't associated with any known input
--
-- Indeed, when kupo is set in 'RemoveSpentInputs' mode, it trims the database
-- as inputs get spent. However, Cardano being a decentralized and only
-- eventually immutable data-source. Indeed, the most recent part of the chain
-- (i.e. last k blocks) _may change unpredictably. By removing 'spent inputs'
-- too early, we may take the risk of removing an input which may be reinstatated
-- later (because the chain forked and the transaction spending that input isn't
-- included in that fork).
--
-- In brief, we can only delete inputs after `k` blocks (or `3*k/f` slots) have
-- passed (since it is guaranteed to have `k` blocks in a `3*k/f` slot window).
gardener
    :: forall m.
        ( MonadSTM m
        , MonadLog m
        , MonadDelay m
        , Monad (DBTransaction m)
        )
    => Tracer IO TraceDatabase
    -> Configuration
    -> (forall a. (Database m -> m a) -> m a)
    -> m Void
gardener tr config withDatabase = forever $ do
    threadDelay pruneThrottleDelay
    logWith tr DatabaseBeginGarbageCollection
    withDatabase $ \Database{..} -> do
        (prunedInputs, prunedBinaryData) <- runReadWriteTransaction $ do
            let
                pruneInputsWhenApplicable =
                    case inputManagement of
                        RemoveSpentInputs -> pruneInputs
                        MarkSpentInputs -> pure 0
             in
                (,) <$> pruneInputsWhenApplicable <*> pruneBinaryData
        logWith tr $ DatabaseExitGarbageCollection { prunedInputs, prunedBinaryData }
  where
    Configuration
        { pruneThrottleDelay
        , inputManagement
        } = config
