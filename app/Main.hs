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
    conn <- try (accept sock) :: IO (Either SomeException (Socket, SockAddr)) 
    case conn of
        Left  _    -> clog "Socket is now closed. Exiting."
        Right conn -> do
            clog "Got a client !"
            runClient conn sock port killedChan clients chatrooms       
            server sock port killedChan clients chatrooms               

loopClient :: Handle -> Socket -> String -> Chan Bool -> MVar Clients -> MVar ChatRooms -> [Int] -> IO ()
loopClient hdl originalSocket port killedChan clients chatrooms joinIds = do
    (kill, timedOut, input) <- waitForInput hdl killedChan 0 joinIds clients
    when (timedOut) (clog "Client timed out")
    when (kill || timedOut) (return ())
    let commandAndArgs = splitOn " " input
    let command = head commandAndArgs
    let args = intercalate " " $ tail commandAndArgs
    case command of
        "HELO"            -> do
            helo hdl args port
            loopClient hdl originalSocket port killedChan clients chatrooms joinIds
        "JOIN_CHATROOM:"  -> do
            (error, id) <- join hdl args port clients chatrooms
            if error then return ()
            else do
                if id `elem` joinIds then loopClient hdl originalSocket port killedChan clients chatrooms joinIds
                else loopClient hdl originalSocket port killedChan clients chatrooms (id:joinIds)
        "LEAVE_CHATROOM:" -> do
            (error, id) <- leave hdl args clients
            if error then return ()
            else do
                loopClient hdl originalSocket port killedChan clients chatrooms (delete id joinIds)
        "DISCONNECT:"     -> do
            error <- disconnect hdl args clients
            unless error (loopClient hdl originalSocket port killedChan clients chatrooms joinIds)
        "CHAT:"           -> do
            error <- chat hdl args clients
            unless error (loopClient hdl originalSocket port killedChan clients chatrooms joinIds)
        _                 -> otherCommand hdl input

runClient :: (Socket, SockAddr) -> Socket -> String -> Chan Bool -> MVar Clients -> MVar ChatRooms -> IO ()
runClient (sock, addr) originalSocket port killedChan clients chatrooms = do
    hdl <- socketToHandle sock ReadWriteMode
    hSetBuffering hdl LineBuffering
    handle (\(SomeException _) -> return ()) $ fix $ (\loop -> (loopClient hdl originalSocket port killedChan clients chatrooms []))
    -- shutdown sock ShutdownBoth
    hClose hdl
    clog "Client disconnected"
