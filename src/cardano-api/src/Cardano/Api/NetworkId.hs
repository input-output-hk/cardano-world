{-# LANGUAGE LambdaCase #-}

-- | The 'NetworkId' type and related functions
--
module Cardano.Api.NetworkId (
    -- * Network types
    NetworkId(..),
    NetworkMagic(..),
    fromNetworkMagic,
    toNetworkMagic,
    mainnetNetworkMagic,

    -- * Internal conversion functions
    toByronProtocolMagicId,
    toByronNetworkMagic,
    toByronRequiresNetworkMagic,
    toShelleyNetwork,
    fromShelleyNetwork,
  ) where

import           Prelude

import           Ouroboros.Network.Magic (NetworkMagic (..))

import qualified Cardano.Chain.Common as Byron (NetworkMagic (..))
import qualified Cardano.Chain.Genesis as Byron (mainnetProtocolMagicId)
import qualified Cardano.Crypto.ProtocolMagic as Byron (ProtocolMagicId (..),
                   RequiresNetworkMagic (..))
import qualified Cardano.Ledger.BaseTypes as Shelley (Network (..))

import Data.Aeson (ToJSON(..), object, (.=), FromJSON(parseJSON), Value(Object, String), (.:?))


-- ----------------------------------------------------------------------------
-- NetworkId type
--

data NetworkId = Mainnet
               | Testnet !NetworkMagic
  deriving (Eq, Show)

-- copied from tx-generator
instance ToJSON NetworkId where
  toJSON Mainnet = "Mainnet"
  toJSON (Testnet (NetworkMagic t)) = object ["Testnet" .= t]

instance FromJSON NetworkId where
  parseJSON j = case j of
    (String "Mainnet") -> return Mainnet
    (Object v) -> v .:? "Testnet" >>= \case
      Nothing -> failed
      Just w -> return $ Testnet $ NetworkMagic w
    _invalid -> failed
    where
      failed = fail $ "Parsing of NetworkId failed: " <> show j

fromNetworkMagic :: NetworkMagic -> NetworkId
fromNetworkMagic nm =
  if nm == mainnetNetworkMagic
  then Mainnet
  else Testnet nm

toNetworkMagic :: NetworkId -> NetworkMagic
toNetworkMagic (Testnet nm) = nm
toNetworkMagic Mainnet      = mainnetNetworkMagic

mainnetNetworkMagic :: NetworkMagic
mainnetNetworkMagic = NetworkMagic
                    . Byron.unProtocolMagicId
                    $ Byron.mainnetProtocolMagicId


-- ----------------------------------------------------------------------------
-- Byron conversion functions
--

toByronProtocolMagicId :: NetworkId -> Byron.ProtocolMagicId
toByronProtocolMagicId Mainnet = Byron.mainnetProtocolMagicId
toByronProtocolMagicId (Testnet (NetworkMagic pm)) = Byron.ProtocolMagicId pm

toByronNetworkMagic :: NetworkId -> Byron.NetworkMagic
toByronNetworkMagic Mainnet                     = Byron.NetworkMainOrStage
toByronNetworkMagic (Testnet (NetworkMagic nm)) = Byron.NetworkTestnet nm

toByronRequiresNetworkMagic :: NetworkId -> Byron.RequiresNetworkMagic
toByronRequiresNetworkMagic Mainnet   = Byron.RequiresNoMagic
toByronRequiresNetworkMagic Testnet{} = Byron.RequiresMagic


-- ----------------------------------------------------------------------------
-- Shelley conversion functions
--

toShelleyNetwork :: NetworkId -> Shelley.Network
toShelleyNetwork  Mainnet    = Shelley.Mainnet
toShelleyNetwork (Testnet _) = Shelley.Testnet

fromShelleyNetwork :: Shelley.Network -> NetworkMagic -> NetworkId
fromShelleyNetwork Shelley.Testnet nm = Testnet nm
fromShelleyNetwork Shelley.Mainnet nm
  | nm == mainnetNetworkMagic = Mainnet
  | otherwise = error "fromShelleyNetwork Mainnet: wrong mainnet network magic"

