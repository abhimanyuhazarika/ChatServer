module Main where
 
import Network.Socket
import System.IO

main :: IO ()
main = do
    sock <- socket AF_INET Stream 0    -- create socket
    setSocketOption sock ReuseAddr 1   -- make socket immediately reusable - eases debugging.
    bind sock (SockAddrInet 4242 iNADDR_ANY)   -- listen on TCP port 4242.
    listen sock 5                              -- set a max of 5 queued connections
    chan <- newChan
    hashTSI <- H.new ::IO (Hashtable String Int)
    hashTIChat <- H.new ::IO (Hashtable Int ChatRoom)
    hashTIClient <- H.new ::IO (Hashtable Int Client)
    hashTSClientName <- H.new ::IO (Hashtable String Int)
    chatRooms<-newMVar(ChatRooms {chatRoomFromId=hashTIChat, chatRoomIdFromName=hashTSI, numberOfChatRooms=0})
    mainLoop sock                              

server :: Socket -> String -> Chan Bool -> MVar Clients -> MVar ChatRooms -> IO ()
server sock port killedChan clients chatrooms = do
    clog "Waiting for incoming connection..."
    conn <- try (accept sock) :: IO (Either SomeException (Socket, SockAddr))  -- try to accept a connection and handle it
    case conn of
        Left  _    -> clog "Socket is now closed. Exiting."
        Right conn -> do
            clog "Got a client !"
            runClient conn sock port killedChan clients chatrooms       -- run our client's logic, then
            server sock port killedChan clients chatrooms               -- repeat


mainLoop :: Socket -> IO ()
mainLoop sock = do
    conn <- accept sock     -- accept a connection and handle it
    runConn conn            -- run our server's logic
    mainLoop sock           -- repeat
runConn :: (Socket, SockAddr) -> IO ()
runConn (sock, _) = do
    hdl <- socketToHandle sock ReadWriteMode
    hSetBuffering hdl NoBuffering
    hPutStrLn hdl "Hello!"
    hClose hdl
