{-# LANGUAGE CPP, OverloadedStrings #-}

-- |Minimal HTTP client implementation
--
-- Note: this implementation only supports a subset of the HTTP
--       protocol for performance-reasons. This implementation is not
--       meant to be used for more than benchmarking purposes.

module Network.HTTP.MicroClient
    ( -- * /Socket Stream/ abstract data type
      SockStream
    , ssFromSocket
    , ssConnect
    , ssToSocket
    , ssClose
    , ssId
    , ssRead
    , ssPeek
    , ssPeekBuf
    , ssRead'
    , ssReadN
    , ssUnRead
    , ssWrite
    , ssReadCnt
    , ssWriteCnt
      -- * HTTP Protocol Handling
    , recvHttpHeaders
    , httpHeaderGetInfos
      -- * Utils
    , getSockAddr
    , splitUrl
    ) where

import           Control.Applicative
import           Control.Exception
import           Control.Monad
import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import           Data.ByteString.Lex.Integral (readDecimal)
import qualified Data.ByteString.Unsafe as B
import           Data.IORef
import           Data.Monoid
import           Data.Tuple
import           Data.Word
import           Network
import           Network.BSD
import           Network.Socket hiding (send, sendTo, recv, recvFrom)
import           Network.Socket.ByteString
import           Network.URI
import           System.IO.Error
import           System.IO.Unsafe (unsafePerformIO)

-- |Minimal socket input-stream abstraction w/ single pushback & consumed byte-count
--
-- This abstraction is inspired by io-streams but is tuned for low-overhead
data SockStream = SockStream {-# NOUNPACK #-} !Socket
                             {-# NOUNPACK #-} !(IORef ByteString)
                             {-# NOUNPACK #-} !(IORef Word64) -- note: does contain readbuf's size
                             {-# NOUNPACK #-} !(IORef Word64) -- data written
                             {-# UNPACK #-}   !Int -- hack: connection-id

-- |Internal debug tracing helper
ssDebug :: String -> SockStream -> IO a -> IO a
#if 0
ssDebug msg (SockStream _ bufref cntref _) act = do
    cnt <- readIORef cntref
    buf <- readIORef bufref
    putStrLn $ "DEBUG: " ++ msg ++ " SockStream _ " ++ show buf ++ " " ++ show cnt
    act
#else
ssDebug _ _ act = act
#endif

-- hack
ssIdCounter :: IORef Int
ssIdCounter = unsafePerformIO $ newIORef 1
{-# NOINLINE ssIdCounter #-}

getSsCounterId :: IO Int
getSsCounterId = atomicModifyIORef' ssIdCounter (\n -> (n+1,n))

-- |Convert an existing 'Socket' into a 'SockStream'
ssFromSocket :: Socket -> IO SockStream
ssFromSocket s = SockStream s <$> newIORef B.empty <*> newIORef 0 <*> newIORef 0 <*> getSsCounterId

-- |Access underlying 'Socket'
ssToSocket :: SockStream -> Socket
ssToSocket (SockStream s _ _ _ _) = s

-- |Access 'SockStream' counter id
--
-- Each created 'SockStream' wrapper has an unique counter id value associated
ssId :: SockStream -> Int
ssId (SockStream _ _ _ _ i) = i

ssClose :: SockStream -> IO ()
ssClose = sClose . ssToSocket

-- |Wrapper that creates TCP/IP IPv4 'SocketStream' and connects to 'SockAddr' created with 'getSockAddr'
ssConnect :: SockAddr -> IO SockStream
ssConnect sa = bracketOnError (socket AF_INET Stream tcpProtoNum)
                              sClose
                              (\sock -> connect sock sa >> ssFromSocket sock)

-- |Read data from stream.
--
-- Note: Returns empty string on EOF. It's often better to use 'ssRead'' instead.
ssRead :: SockStream -> IO ByteString
ssRead ss@(SockStream s bufref rcntref _ _) = ssDebug "ssRead" ss $ do
    buf <- readIORef bufref
    if B.null buf
    then do
        buf' <- recv s 32752 -- 32KiB - 16byte bytestring-overhead
        modifyIORef' rcntref (+ (fromIntegral $ B.length buf'))
        return buf'
    else do
        writeIORef bufref B.empty
        return buf

-- |Version of 'ssRead' that throws
ssRead' :: SockStream -> IO ByteString
ssRead' ss = do
    buf <- ssRead ss
    if B.null buf then ioError eofEx else return buf
  where
    eofEx = mkIOError eofErrorType "ssRead'" Nothing Nothing

-- |Version of 'ssRead' which does not consume the data returned
--
-- That is, @ssPeek ss@ is semantically equivalent to
-- @do { b <- ssRead ss; ssUnRead b ss; return b}@.
--
-- 'ssPeek' is idempotent, i.e. @ssPeek ss == ssPeek ss >> ssPeek ss@
ssPeek :: SockStream -> IO ByteString
ssPeek ss@(SockStream s bufref rcntref _ _) = ssDebug "ssPeek" ss $ do
    buf <- readIORef bufref
    if B.null buf
    then do
        buf' <- recv s 32752 -- 32KiB - 16byte bytestring-overhead
        modifyIORef' rcntref (+ (fromIntegral $ B.length buf'))
        writeIORef bufref buf'
        return buf'
    else do
        writeIORef bufref B.empty
        return buf

-- |May return empty string if no data has been buffered yet
ssPeekBuf :: SockStream -> IO ByteString
ssPeekBuf ss@(SockStream _ bufref _ _ _) =
    ssDebug "ssPeekBuf" ss $ readIORef bufref

-- |Read exactly n bytes from 'SocketStream'; throws exception if connection is closed
ssReadN :: SockStream -> Word64 -> IO ByteString
ssReadN ss@(SockStream s bufref rcntref _ _) l0 = ssDebug "ssRead'" ss $ do
    buf <- readIORef bufref
    let l    = fromIntegral l0
        need = l - B.length buf

    if need <= 0
    then
        atomicModifyIORef' bufref (swap . B.splitAt l)
    else do
        (res,buf') <- go need buf
        let rcntdelta = B.length buf' + B.length res - B.length buf
        writeIORef   bufref $! buf'
        modifyIORef' rcntref (+ fromIntegral rcntdelta)
        return res

  where
    go n bufa
      | n >  0     = do
          buf <- recv s 32752
          let l = B.length buf
          if l > n
          then -- more than enough (this is an optimization)
              return (bufa <> B.unsafeTake n buf, B.unsafeDrop n buf)
          else do -- not enough
              unless (l>0) $ ioError eofEx
              go (n-l) (bufa <> buf)
      | n == 0     = return (bufa,B.empty)
      | otherwise  = return $ B.splitAt n bufa

    eofEx = mkIOError eofErrorType "ssReadN" Nothing Nothing

-- |Push-back read data into 'SockStream'
ssUnRead :: ByteString -> SockStream -> IO ()
ssUnRead buf0 ss@(SockStream _ bufref _ _ _) =
    ssDebug "ssUnRead" ss $ modifyIORef' bufref (<> buf0)

-- |Returns length of data consumed (i.e. w/o 'ssUnRead' data)
ssReadCnt :: SockStream -> IO Word64
ssReadCnt ss@(SockStream _ bufref rcntref _ _) = ssDebug "ssReadCnt" ss $ do
    buf <- readIORef bufref
    rcnt <- readIORef rcntref
    return $! rcnt - fromIntegral (B.length buf)

-- |Write data out to socket (uses 'sendAll' internally)
ssWrite :: ByteString -> SockStream -> IO ()
ssWrite buf ss@(SockStream s _ _ wcntref _) = ssDebug "ssWrite" ss $ do
    sendAll s buf
    modifyIORef' wcntref (+ (fromIntegral $ B.length buf))

-- |Returns length of data written to stream
ssWriteCnt :: SockStream -> IO Word64
ssWriteCnt (SockStream _ _ _ wcntref _) = readIORef wcntref

----------------------------------------------------------------------------
-- Helpers

-- |Used by 'ssConnect'
tcpProtoNum :: ProtocolNumber
tcpProtoNum = unsafePerformIO $ getProtocolNumber "tcp"
{-# NOINLINE tcpProtoNum #-}

-- |Construct IPv4 'SockAddr'
getSockAddr :: HostName -> PortNumber -> IO SockAddr
getSockAddr hostname port = do
    he <- getHostByName hostname
    return $! SockAddrInet port (hostAddress he)

-- |Extract information from the header lines as returned by 'recvHttpHeaders'
--
-- returns: (status-code, close-conn, Just content-length /or/ Nothing (i.e. chunked))
httpHeaderGetInfos :: [ByteString] -> (Int, Bool, Maybe Int)
httpHeaderGetInfos hds0
    | ver /= "HTTP/1.1" = error "unsupported HTTP version"
    | otherwise         = (code, connClose, if chunkTx then Nothing else Just clen)
  where
    hds = init hds0
    (ver:code':_) = B.split 0x20 (last hds0) -- FIXME

    code | Just (n,_) <- readDecimal code' = n
         | otherwise = -1

    -- FIXME/TODO: find an efficient way to perform case-insensitive header-matching
    connClose = "Connection: close" `elem` hds
    chunkTx   = "Transfer-Encoding: chunked" `elem` hds

    clen | (h:_) <- filter ("Content-Length: " `B.isPrefixOf`) hds =
                 case readDecimal (B.unsafeDrop 16 h) of
                     Just (n,_) -> n
                     Nothing    -> -1
         | otherwise = 0

    -- toLowerW8 w | 65 <= w, w <=  90 = w + 32 :: Word8
    --             | otherwise         = w

-- |Receive/consume HTTP response from 'SockStream'
--
-- If no exception occured during 'recvHttpHeaders' the 'SockStream'
-- is left at the beginning of the (potentially empty) HTTP response
-- body.
recvHttpHeaders :: SockStream -> IO [ByteString]
recvHttpHeaders ss = do
    res <- ssRead' ss
    (buf,h0:hds) <- go $ httpParseHeader (res,[])
    unless (B.null h0) $ fail "recvHttpHeaders"
    ssUnRead buf ss
    return hds
  where
    go st@(res,hds) -- result of httpParseHeader invocation
      | httpParseHeaderDone st = return st -- header parsing finished
      | otherwise = do
          buf <- ssRead' ss
          go $ httpParseHeader (res <> buf,hds)

    -- note: headers are in reverse
    httpParseHeader :: (ByteString,[ByteString]) -> (ByteString,[ByteString])
    httpParseHeader (s0,acc)
      | Just i <- B.elemIndex 10 s0 =
          let (line1,rest1) = (stripCR $ B.unsafeTake i s0, B.unsafeDrop (i+1) s0)
          in (if B.null line1 then id else httpParseHeader) (rest1,line1:acc)
      | otherwise = (s0, acc) -- need more data
      where
        stripCR = fst . B8.spanEnd (=='\r')

    httpParseHeaderDone :: (ByteString,[ByteString]) -> Bool
    httpParseHeaderDone (_,l:_) | B.null l = True
    httpParseHeaderDone _ = False

-- |Split HTTP URL into (hostname,port,url-path)
splitUrl :: String -> Either String (String,PortNumber,String)
splitUrl url0 = do
    uri <- note "invalid URI" $ parseAbsoluteURI url0

    unless (uriScheme uri == "http:") $
        Left "URI must have 'http' scheme"

    urlauth <- note "missing host-part in URI" $ uriAuthority uri
    let hostname = uriRegName urlauth

    when (null hostname) $
        Left "empty hostname in URL"

    unless (null . uriUserInfo $ urlauth) $
        Left "user/pass in URL not supported"

    portnum <- case uriPort urlauth of
        ""      -> return 80
        ':':tmp -> return $! fromIntegral (read tmp :: Word)
        _       -> Left "invalid port-number"

    return (hostname,portnum,if null (uriPath uri) then "/" else uriPath uri)

  where
    -- | Tag the 'Nothing' value of a 'Maybe'
    note :: a -> Maybe b -> Either a b
    note a = maybe (Left a) Right