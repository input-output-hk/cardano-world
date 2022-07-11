import           Test.Hspec

import           Test.GetAllMetrics
import           Test.GetMetrics

main :: IO ()
main = hspec $ do
  describe "EKG metrics forwarding, via local pipe" $ do
    it "request of all metrics"
      getAllMetricsViaPipe
    it "request of some metrics"
      getMetricsViaPipe
  describe "EKG metrics forwarding, via remote socket" $ do
    it "request of all metrics"
      getAllMetricsViaSocket
    it "request of some metrics"
      getMetricsViaSocket
