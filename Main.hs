{-# LANGUAGE DeriveGeneric #-}
module Main where

import Control.Concurrent
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Data.Binary
import Data.Foldable
import qualified Data.List as List
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Monoid
import Data.Ord
import Data.Time.Clock.POSIX
import GHC.Generics
import Network.Transport hiding (send)
import Network.Transport.TCP
import qualified Options.Applicative
import Options.Applicative hiding (info)
import System.IO
import System.Random

type Clock = Int

type Host = String

type Port = Int

data Stop = Stop
          deriving (Generic)

instance Binary Stop

-- | the message this challenge is about: consisting of 
--   - a sequence number
--   - a float value
--
-- An emitter will never send two messages with the same
-- sequence number.
data EmitFloat = EmitFloat !Int !Float
               deriving (Generic)

instance Binary EmitFloat

emitFloatSeq :: EmitFloat -> Int
emitFloatSeq (EmitFloat s _) = s

-- | A transport envelope for our float message.
data EmitFloatEnv = EmitFloatEnv !ProcessId !Clock !EmitFloat
                  deriving (Generic)

instance Binary EmitFloatEnv

data AskResult = AskResult !ProcessId
               | AskResultReply !Int !Int !Float
               deriving (Generic)

instance Binary AskResult

nodeAddresses :: [(Host, Port)]
nodeAddresses =
  [ ("127.0.0.1", 8081)
  , ("127.0.0.1", 8082)
  , ("127.0.0.1", 8083)
  , ("127.0.0.1", 8084)
  ]

allNodes :: [NodeId]
allNodes =
  [ NodeId (encodeEndPointAddress host (show port) 0)
  | (host, port) <- nodeAddresses
  ]

collectorProcess :: String
collectorProcess = "iohk-collector"

boot :: Int -> Int -> Int -> Process ()
boot sendFor waitFor seed = do

  self <- getSelfNode
  
  let
    randomSeries :: [Float]
    -- transform the random floats from interval [0, 1)
    -- to (0, 1].
    randomSeries = map (1.0 -) (randoms (mkStdGen seed))

    -- we hand the emitter this unlimited supply of EmitFloat
    -- values
    emitFloatSeries :: [EmitFloat]
    emitFloatSeries = zipWith EmitFloat [0..] randomSeries 

    -- don't include current node in the receivers
    nodes :: [NodeId]
    nodes = [ node | node <- allNodes,  self /= node ]
            
  -- Collector process
  collector <- spawnLocal collect
  -- publish the process
  register collectorProcess collector
  -- Emitter process
  emitter <- spawnLocal (emit emitFloatSeries nodes)

  info $ "Sending for " ++ show sendFor ++ " seconds"
  liftIO $ threadDelay (1000000 * sendFor)
  send emitter Stop

  info $ "Gracefully waiting for " ++ show waitFor ++ " seconds"
  liftIO $ threadDelay (1000000 * waitFor)    
  selfPid <- getSelfPid
  send collector (AskResult selfPid)
  AskResultReply count missing result <- expect

  info $ "Received messages " ++ show count
  info $ "Missing messages " ++ show missing
  liftIO $ hPutStrLn stdout (show (count, result))

  return ()

-- broadcasts floats to all nodes in a fire and
-- forget manner.
emit :: [EmitFloat] -> [NodeId] -> Process ()
emit values receivers = go 0 values
  where
    go :: Int -> [EmitFloat] -> Process ()
    go n (v : vx) = do
      -- non-blockingly check for `Stop` signal
      mStop <- expectTimeout 0
      case mStop of
        Just Stop -> do
          info $ "Emitted " ++ show n ++ " floats"
          return ()
        _         -> do
          self      <- getSelfPid
          timestamp <- round <$> liftIO getPOSIXTime :: Process Clock
          let msg = EmitFloatEnv self timestamp v
          for_ receivers (\node -> nsendRemote node collectorProcess msg)
          go (n + 1) vx
    go _ [] = return ()

-- float collector
collect :: Process a
collect = go Map.empty
  where
    -- calculate the result from the received messages
    result :: Map NodeId [(EmitFloat, Clock)] -> (Int, Float)
    result msgs = (length sorted, foldr f 0.0 (map fst sorted))
      where
        f :: EmitFloat -> Float -> Float
        f (EmitFloat i v) acc = acc + fromIntegral i * v

        sorted :: [(EmitFloat, Clock)]
        sorted = 
          List.sortBy (comparing snd) (List.concat (Map.elems msgs))

    -- since each EmitFloat is numbered sequentially we can easily
    -- determine what the missing messages are.
    countMissing :: Map NodeId [(EmitFloat, Clock)] -> Int
    countMissing msgs =
      sum [ n
          | values <-
              map (List.sortBy (comparing (emitFloatSeq . fst))) (Map.elems msgs)
          , let (_, n) = foldr
                  (\x (lastX, acc) -> (x, acc + (lastX - x)))
                  (0, 0)
                  (map (emitFloatSeq . fst) values)
          ]
         
    -- receive new emitted floats and wait for timeout
    go :: Map NodeId [(EmitFloat, Clock)] -> Process a
    go msgs = do
      cmd <- receiveWait
        [ match (\(emitFloatEnv@EmitFloatEnv{}) -> return (Right emitFloatEnv))
        , match (\askResult@AskResult{} -> return (Left askResult))
        ]
      case cmd of
        Right (EmitFloatEnv sender timestamp emitFloat) -> 
          -- We have just received an EmitFloat from a remote peer.
          -- Since every EmitFloat has a sequence number we can easily
          -- determine if we missed messages from that peer in the past.
          -- We could now ask other nodes to forward these missing messages
          -- to us.
          go (Map.insertWith
               (++) -- using (++) here is ok: it is [new] ++ old, not old ++ [new]
               (processNodeId sender)
               [(emitFloat, timestamp)] msgs)
        Left (AskResult sender) -> do
          let (count, val) = result msgs
              missing      = countMissing msgs
          send sender (AskResultReply count missing val)
          go msgs
        _ -> go msgs

info :: String -> Process ()
info msg = do
  pid <- getSelfPid
  let text = show pid ++ ": " ++ msg
  liftIO (hPutStrLn stderr text)

main :: IO ()
main = do

  let options =
        (,,,,) <$> option auto (long "send-for" <> metavar "SECONDS" <> value 20)
               <*> option auto (long "wait-for" <> metavar "SECONDS" <> value 10)
               <*> option auto (long "with-seed" <> metavar "INT" <> value 123456)
               <*> option auto (long "host" <> metavar "HOST" <> value "127.0.0.1")
               <*> option auto (long "port" <> metavar "PORT" <> value (8081 :: Int))
  
  (sendFor, waitFor, seed, host, port) <-
    execParser (Options.Applicative.info (options <**> helper) mempty)

  Right transport <-
    createTransport host (show port) defaultTCPParameters
  node <- newLocalNode transport initRemoteTable
  runProcess node (boot sendFor waitFor seed)
  closeTransport transport  
