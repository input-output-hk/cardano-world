{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}

module Cardano.Tracing.Constraints
  ( TraceConstraints
  ) where

import           Data.Aeson

import           Cardano.BM.Tracing (ToObject)
import           Cardano.Tracing.Queries (LedgerQueries)

import           Ouroboros.Consensus.Block (BlockProtocol, CannotForge,
                     ForgeStateUpdateError, Header)
import           Ouroboros.Consensus.HeaderValidation (OtherHeaderEnvelopeError)
import           Ouroboros.Consensus.Ledger.Abstract (LedgerError)
import           Ouroboros.Consensus.Ledger.Inspect (LedgerEvent)
import           Ouroboros.Consensus.Ledger.SupportsMempool (ApplyTxErr,  HasTxId,
                     HasTxs (..))
import           Ouroboros.Consensus.Protocol.Abstract (ValidationErr)
import           Ouroboros.Consensus.Shelley.Ledger.Mempool (GenTx, TxId)
import           Ouroboros.Consensus.Util.Condense (Condense)


-- | Tracing-related constraints for monitoring purposes.
--
-- When you need a 'Show' or 'Condense' instance for more types, just add the
-- appropriate constraint here. There's no need to modify the consensus
-- code-base, unless the corresponding instance is missing. Note we are aiming to
-- remove all `Condense` constaints by defining the relevant 'ToObject' instance
-- in 'cardano-node'
type TraceConstraints blk =
    ( Condense (TxId (GenTx blk))
    , HasTxs blk
    , HasTxId (GenTx blk)
    , LedgerQueries blk
    , ToJSON   (TxId (GenTx blk))
    , ToObject (ApplyTxErr blk)
    , ToObject (GenTx blk)
    , ToObject (Header blk)
    , ToObject (LedgerError blk)
    , ToObject (LedgerEvent blk)
    , ToObject (OtherHeaderEnvelopeError blk)
    , ToObject (ValidationErr (BlockProtocol blk))
    , ToObject (CannotForge blk)
    , ToObject (ForgeStateUpdateError blk)
    )
