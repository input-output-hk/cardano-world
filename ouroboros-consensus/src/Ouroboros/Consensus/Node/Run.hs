{-# LANGUAGE FlexibleContexts #-}

-- | Infrastructure required to run a node
--
-- The definitions in this module are independent from any specific protocol.
module Ouroboros.Consensus.Node.Run (
    -- * SerialiseDisk
    SerialiseDiskConstraints
  , ImmDbSerialiseConstraints
  , LgrDbSerialiseConstraints
  , VolDbSerialiseConstraints
    -- * SerialiseNodeToNode
  , SerialiseNodeToNodeConstraints
    -- * SerialiseNodeToClient
  , SerialiseNodeToClientConstraints
    -- * RunNode
  , RunNode (..)
  ) where

import           Ouroboros.Network.Block (HeaderHash, Serialised)
import           Ouroboros.Network.BlockFetch (SizeInBytes)

import           Ouroboros.Consensus.Block
import           Ouroboros.Consensus.Config
import           Ouroboros.Consensus.Config.SupportsNode
import           Ouroboros.Consensus.HardFork.Abstract
import           Ouroboros.Consensus.Ledger.Abstract
import           Ouroboros.Consensus.Ledger.SupportsMempool
import           Ouroboros.Consensus.Ledger.SupportsProtocol
import           Ouroboros.Consensus.Node.NetworkProtocolVersion
import           Ouroboros.Consensus.Node.Serialisation
import           Ouroboros.Consensus.Util.IOLike

import           Ouroboros.Consensus.Storage.ChainDB (ImmDbSerialiseConstraints,
                     LgrDbSerialiseConstraints, SerialiseDiskConstraints,
                     VolDbSerialiseConstraints)
import           Ouroboros.Consensus.Storage.ChainDB.Init (InitChainDB)
import           Ouroboros.Consensus.Storage.ChainDB.Serialisation
import           Ouroboros.Consensus.Storage.Common (BinaryBlockInfo (..))
import           Ouroboros.Consensus.Storage.ImmutableDB (ChunkInfo)

{-------------------------------------------------------------------------------
  RunNode proper
-------------------------------------------------------------------------------}

-- | Serialisation constraints needed by the node-to-node protocols
class ( SerialiseNodeToNode blk (HeaderHash blk)
      , SerialiseNodeToNode blk blk
      , SerialiseNodeToNode blk (Header blk)
      , SerialiseNodeToNode blk (Serialised blk)
      , SerialiseNodeToNode blk (SerialisedHeader blk)
      , SerialiseNodeToNode blk (GenTx blk)
      , SerialiseNodeToNode blk (GenTxId blk)
      ) => SerialiseNodeToNodeConstraints blk

-- | Serialisation constraints needed by the node-to-client protocols
class ( SerialiseNodeToClient blk (HeaderHash blk)
      , SerialiseNodeToClient blk blk
      , SerialiseNodeToClient blk (Serialised blk)
      , SerialiseNodeToClient blk (GenTx blk)
      , SerialiseNodeToClient blk (ApplyTxErr blk)
      , SerialiseNodeToClient blk (Some (Query blk))
      , SerialiseResult       blk (Query blk)
      ) => SerialiseNodeToClientConstraints blk

class ( LedgerSupportsProtocol           blk
      , HasHardForkHistory               blk
      , LedgerSupportsMempool            blk
      , HasTxId                   (GenTx blk)
      , QueryLedger                      blk
      , TranslateNetworkProtocolVersion  blk
      , CanForge                         blk
      , ConfigSupportsNode               blk
      , HasCodecConfig                   blk
      , ConvertRawHash                   blk
      , SerialiseDiskConstraints         blk
      , SerialiseNodeToNodeConstraints   blk
      , SerialiseNodeToClientConstraints blk
      ) => RunNode blk where
  nodeBlockFetchSize      :: Header blk -> SizeInBytes

  nodeImmDbChunkInfo      :: TopLevelConfig blk -> ChunkInfo

  -- | Check the integrity of a block, i.e., that it has not been corrupted by
  -- a bitflip.
  --
  -- Check this by, e.g., verifying whether the block has a valid signature
  -- and that the hash of the body matches the body hash stores in the header.
  --
  -- This does not check the validity of the contents of the block, e.g.,
  -- whether the transactions are valid w.r.t. the ledger, or whether it's
  -- sent by a malicious node.
  nodeCheckIntegrity :: TopLevelConfig blk -> blk -> Bool

  -- | Return information about the serialised block, i.e., how to extract the
  -- bytes corresponding to the header from the serialised block.
  nodeGetBinaryBlockInfo :: blk -> BinaryBlockInfo

  -- | This function is called when starting up the node, right after the
  -- ChainDB was opened, and before we connect to other nodes and start block
  -- production.
  --
  -- This function can be used to, for example, create the genesis EBB in case
  -- the chain(DB) is empty.
  --
  -- We only provide a limited interface to the chain DB. This is primarily
  -- useful for the definition of combinators (which may need to turn a
  -- 'InitChainDB' for one type of block into an 'InitChainDB' for a closely
  -- related type of block).
  nodeInitChainDB :: IOLike m
                  => TopLevelConfig blk
                  -> InitChainDB m blk
                  -> m ()
  nodeInitChainDB _ _ = return ()
