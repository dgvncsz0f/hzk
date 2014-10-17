{-# LANGUAGE TupleSections #-}

-- This file is part of zhk
--
-- All rights reserved.
--  
-- Redistribution and use in source and binary forms, with or without modification,
-- are permitted provided that the following conditions are met:
--  
--   Redistributions of source code must retain the above copyright notice, this
--   list of conditions and the following disclaimer.
--  
--   Redistributions in binary form must reproduce the above copyright notice, this
--   list of conditions and the following disclaimer in the documentation and/or
--   other materials provided with the distribution.
--  
--   Neither the name of the {organization} nor the names of its
--   contributors may be used to endorse or promote products derived from
--   this software without specific prior written permission.
--  
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
-- ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
-- WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
-- DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
-- ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
-- (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
-- LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
-- ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
-- (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
-- SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

--------------------------------------------------------------------------------
-- |
-- Module        : Database.Zookeeper.Pool
-- Copyright     : (C) 2013 Diego Souza
-- License       : BSD-style (see the file LICENSE)
--
-- Maintainer    : Diego Souza <dsouza@c0d3.xxx>
-- Stability     : experimental
--
-- Zookeeper client library
--------------------------------------------------------------------------------
module Database.Zookeeper.Pool
       ( -- * Description
         -- $description

         -- * Example
         -- $example

         -- * Notes
         -- $notes

         -- * Connection
         connect
       ) where

import           Foreign.C
import           Foreign.Safe
import           Database.Zookeeper.CApi
import           Database.Zookeeper.Types
import qualified Data.Pool as P
import           Data.Time

-- | Connects to the zookeeper cluster. This function may throw an
-- exception if a valid zookeeper handle could not be created.
--
-- The connection is terminated right before this function returns.
connect :: String
        -- ^ The zookeeper endpoint to connect to. This is given
        -- as-is to the underlying C API. Briefly, host:port
        -- separated by comma. At the end, you may define an
        -- optional chroot, like the following:
        --   localhost:2181,localhost:2182/foobar
        -> Timeout
        -- ^ The session timeout (milliseconds)
        -> Maybe Watcher
        -- ^ The global watcher function. When notifications are
        -- triggered this function will be invoked
        -> Maybe ClientID
        -- ^ The id of a previously established session that
        -- this client will be reconnecting to
        -> Int
        -- ^ The number of stripes (distinct sub-pools) to maintain.
        -- The smallest acceptable value is 1.
        -> NominalDiffTime
        -- ^ Amount of time for which an unused resource is kept open.
        -- The smallest acceptable value is 0.5 seconds.
        --
        -- The elapsed time before destroying a resource may be a little
        -- longer than requested, as the reaper thread wakes at 1-second
        -- intervals.
        -> Int
        -- ^ Maximum number of resources to keep open per stripe.  The
        -- smallest acceptable value is 1.
        --
        -- Requests for resources will block if this limit is reached on a
        -- single stripe, even if other stripes have idle resources
        -- available.
        -> IO (P.Pool Zookeeper)
connect endpoint timeout watcher clientId numStripes idleTime maxResources = do
  P.createPool
    (open endpoint timeout watcher)
    close
    numStripes idleTime maxResources
  where
    open endpoint' timeout' watcher' = do
      withCString endpoint' $ \strPtr -> do
        cWatcher <- wrapWatcher watcher'
        zh <- throwIfNull "zookeeper_init" $ c_zookeeperInit strPtr cWatcher (fromIntegral timeout') cClientIdPtr nullPtr 0
        return (Zookeeper zh)
    close (Zookeeper zh) = c_zookeeperClose zh
    cClientIdPtr = case clientId of
      Nothing             -> nullPtr
      Just (ClientID ptr) -> ptr
