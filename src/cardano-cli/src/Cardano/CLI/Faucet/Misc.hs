{-# LANGUAGE ImportQualifiedPost #-}

module Cardano.CLI.Faucet.Misc where

import Cardano.Api (ConsensusModeParams(CardanoModeParams), CardanoMode, EpochSlots(EpochSlots), AddressAny, parseAddressAny, TxOutValue(TxOutAdaOnly, TxOutValue), CardanoEra, EraInMode, toEraInMode, ConsensusMode(CardanoMode),AssetId(AdaAssetId), quantityToLovelace, Quantity, valueToList)
import Cardano.Prelude
import Cardano.CLI.Faucet.Types
import Data.Text qualified as T
import Text.Parsec
import Control.Monad.Trans.Except.Extra (left)

getValue :: TxOutValue era -> FaucetValue
getValue (TxOutAdaOnly _ ll) = Ada ll
getValue (TxOutValue _ val) = convertValue $ valueToList val
  where
    convertValue :: [(AssetId, Quantity)] -> FaucetValue
    convertValue [(AdaAssetId, q)] = Ada $ quantityToLovelace q
    convertValue other = FaucetValueMultiAsset other

parseAddress :: Text -> ExceptT FaucetWebError IO AddressAny
parseAddress addr = case parse (parseAddressAny <* eof) "" (T.unpack addr) of
  Right a -> return $ a
  Left e -> left $ FaucetWebErrorInvalidAddress addr (show e)

defaultCModeParams :: ConsensusModeParams CardanoMode
defaultCModeParams = CardanoModeParams (EpochSlots defaultByronEpochSlots)

defaultByronEpochSlots :: Word64
defaultByronEpochSlots = 21600

convertEra :: Monad m => CardanoEra era -> ExceptT FaucetWebError m (EraInMode era CardanoMode)
convertEra era = case (toEraInMode era CardanoMode) of
  Just eraInMode -> pure eraInMode
  Nothing -> left $ FaucetWebErrorEraConversion
