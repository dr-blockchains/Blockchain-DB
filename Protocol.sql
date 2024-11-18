CREATE TABLE Accounts (
    public_key BINARY(32) PRIMARY KEY, 
    created_at DATETIME2 DEFAULT SYSDATETIME(),
    balance BIGINT DEFAULT 0 CHECK (balance >= 0) -- Call get_balance(public_key) instead.
); 

CREATE TABLE Blocks ( 
    block_id INT IDENTITY(0,1) PRIMARY KEY, -- Starts from zero
    time_stamp INT CHECK (time_stamp > 0), -- Unix timestamp (seconds since 1970)
    miner BINARY(32) REFERENCES Accounts(public_key), -- FOREIGN KEY (miner)
    block_hash BINARY(32) UNIQUE, -- Only one block can be open at a time (block_hash IS NULL).
    previous_hash BINARY(32) REFERENCES Blocks(block_hash), -- FOREIGN KEY (previous_hash) 
    merkle_root BINARY(32), 
    nonce INT
); 
CREATE INDEX idx_blocks_hash ON Blocks(block_hash) INCLUDE (time_stamp, miner);

CREATE TABLE Transactions (
    tx_id INT IDENTITY PRIMARY KEY, -- AUTO_INCREMENT 
    block_id INT REFERENCES Blocks(block_id), -- FOREIGN KEY (block_id) 
    tx_hash BINARY(32), -- SHA-256: NULL when the transaction is open, calculated at closure. 
    tx_fee BIGINT CHECK (tx_fee >= 0) -- Call transaction_fee(tx_id) instead.
); 
CREATE INDEX idx_transaction_block ON Transactions(block_id);
CREATE INDEX idx_transactions_hash ON Transactions(tx_hash) INCLUDE (block_id, tx_fee);

CREATE TABLE Parties ( 
    -- surrogate_key INT IDENTITY PRIMARY KEY, 
    tx_id INT NOT NULL REFERENCES Transactions(tx_id), -- FOREIGN KEY (transaction)
    public_key BINARY(32) NOT NULL REFERENCES Accounts(public_key), -- FOREIGN KEY (account)
    utxo BIGINT NOT NULL,  -- Positive for receiver, negative for sender
    signature BINARY(32), -- NULL for receiver 
    PRIMARY KEY (tx_id, public_key) 
); 
CREATE INDEX idx_party_transaction ON Parties(tx_id);
CREATE INDEX idx_party_account ON Parties(public_key);

-- Revoke modification privileges from all users on every table.
REVOKE UPDATE, DELETE ON Blocks FROM PUBLIC;
REVOKE UPDATE, DELETE ON Transactions FROM PUBLIC;
REVOKE UPDATE, DELETE ON Accounts FROM PUBLIC;
REVOKE UPDATE, DELETE ON Parties FROM PUBLIC;

-- Ensure only procedures can insert into Blocks and Transactions. 
REVOKE INSERT ON Blocks FROM PUBLIC;
REVOKE INSERT ON Transactions FROM PUBLIC;

-- Grant append-only access to specific tables.
GRANT INSERT ON Accounts TO PUBLIC;
GRANT INSERT ON Parties TO PUBLIC;

-- Grant read-only access to all users.
GRANT SELECT ON Blocks TO PUBLIC;
GRANT SELECT ON Transactions TO PUBLIC;
GRANT SELECT ON Accounts TO PUBLIC;
GRANT SELECT ON Parties TO PUBLIC;

GO

CREATE TRIGGER protect_parties ON Parties 
INSTEAD OF UPDATE, DELETE
AS 
BEGIN 
    RAISERROR('UPDATE or DELETE is not allowed on Parties.', 16, 1);
END
GO 

CREATE TRIGGER protect_closed_transactions ON Parties 
AFTER INSERT 
AS 
BEGIN
    -- Check if any inserted row references a closed or non-existent transaction.
    IF EXISTS (SELECT 1 
                FROM INSERTED i LEFT JOIN Transactions t 
                    ON i.tx_id = t.tx_id
                WHERE t.tx_hash IS NOT NULL 
                    OR t.tx_id IS NULL) 
        THROW 51000, 'Can only insert rows that refer to open transactions.', 1;

    
    IF EXISTS (SELECT 1 
                FROM INSERTED 
                WHERE utxo < 0   -- sender
                    AND signature IS NULL) -- Should be: verify(public_key, signature, utxo)
        THROW 51000, 'Every sender should have a valid signature.', 1;
END
GO

-- Function to calculate the balance of a given account
CREATE OR ALTER FUNCTION get_balance(@public_key BINARY(32)) 
    RETURNS BIGINT 
AS
BEGIN 
    DECLARE @balance BIGINT; 

    SELECT @balance = COALESCE(SUM(utxo), 0) 
    FROM Parties 
    WHERE public_key = @public_key AND 
        tx_id IN (SELECT tx_id 
                    FROM Transactions 
                    WHERE tx_hash IS NOT NULL);

    RETURN @balance; 
END;
GO

-- Function to calculate the confirmed balance of a given account
CREATE OR ALTER FUNCTION confirmed_balance(@public_key BINARY(32)) 
    RETURNS BIGINT 
AS
BEGIN 
    DECLARE @balance BIGINT; 

    SELECT @balance = COALESCE(SUM(utxo), 0) 
    FROM Parties 
    WHERE public_key = @public_key AND 
        tx_id IN (SELECT tx_id 
                    FROM Transactions 
                    WHERE tx_hash IS NOT NULL
                        AND block_id IS NOT NULL); 

    RETURN @balance; 
END;
GO

-- Function to calculate the surplus (fee) of a transaction (inputs - outputs)
CREATE OR ALTER FUNCTION transaction_fee(@tx_id INT)
    RETURNS BIGINT 
AS
BEGIN
    RETURN (SELECT -COALESCE(SUM(utxo), 0) 
            FROM Parties 
            WHERE tx_id = @tx_id);
END;
GO 

CREATE OR ALTER PROCEDURE new_transaction
    @tx_id INT OUTPUT 
AS
BEGIN
    INSERT INTO Transactions (block_id, tx_hash, tx_fee)
        VALUES (NULL, NULL, NULL);
    SET @tx_id = SCOPE_IDENTITY() -- Capture the transaction ID
END;
GO

CREATE OR ALTER PROCEDURE close_transaction
    @tx_id INT
AS
BEGIN
    IF NOT EXISTS (SELECT 1 
                    FROM Transactions 
                    WHERE tx_id = @tx_id 
                        AND tx_hash IS NULL)
        THROW 51000, 'Transaction already closed or does not exist.', 1;

    DECLARE @tx_fee BIGINT = dbo.transaction_fee(@tx_id);
    IF @tx_fee < 0
    BEGIN
        PRINT 'Invalid transaction: Inputs must be greater than or equal to outputs.';
        RETURN;
    END;

    IF EXISTS (
        SELECT 1 
        FROM Parties p 
        WHERE p.tx_id = @tx_id 
            AND p.utxo < 0 
            AND dbo.get_balance(p.public_key) + p.utxo < 0
        )
    BEGIN
        PRINT 'Insufficient balance: One or more senders do not have enough balance.'; 
        RETURN;
    END; 

    DECLARE @tx_hash BINARY(32) = HASHBYTES('SHA2_256', (
        SELECT STRING_AGG(CAST(public_key AS CHAR(32)) +
                CAST(utxo AS CHAR(20)) + 
                COALESCE(CAST(signature AS CHAR(32)),'0'), '')
        FROM Parties 
        WHERE tx_id = @tx_id));

    -- Update the transaction record with the calculated hash and tx_fee
    UPDATE Transactions
    SET tx_hash = @tx_hash, 
        tx_fee = @tx_fee
    WHERE tx_id = @tx_id; 
    
    UPDATE Accounts
    SET balance = COALESCE(balance, 0) + p.utxo
    FROM Parties p
    WHERE p.tx_id = @tx_id
        AND p.public_key = Accounts.public_key;
END;


GO
CREATE OR ALTER PROCEDURE close_block 
    @time_stamp INT, -- Timestamp of the block
    @miner BINARY(32), -- Miner's public key
    @min_fee BIGINT, -- Minimum fee required by the miner
    @gnonce INT -- The Golden Nonce that results in a valid hash
AS 
BEGIN 
    DECLARE @block_id INT,
            @previous_hash BINARY(32), 
            @all_tx_hashes VARCHAR(MAX), 
            @block_fees BIGINT,
            @block_reward BIGINT, 
            @coinbase_reward BIGINT, 
            @coinbase_tx_id INT, 
            @tx_hash BINARY(32), 
            @merkle_root BINARY(32), 
            @block_hash BINARY(32), 
            @version INT,
            @bits INT, 
            @target BINARY(32);

    SELECT  @block_id = block_id, 
            @previous_hash = previous_hash 
    FROM Blocks
    WHERE block_hash IS NULL; 

    IF @block_id IS NULL
     THROW 51000, 'There is no open block!', 1;

    -- No transaction should be in this block yet. 
    UPDATE Transactions 
    SET block_id = NULL
    WHERE block_id = @block_id;

    BEGIN TRANSACTION;
    
    -- Add only the valid transaction records to this block.
    UPDATE Transactions 
    SET block_id = @block_id
    WHERE block_id IS NULL -- Transaction should not belong to a block yet
        AND tx_hash IS NOT NULL -- Only closed transactions
        AND tx_fee >= @min_fee; -- Meets miner's minimum fee requirment 

        -- AND NOT EXISTS (  -- Exclude transactions resulting in a negative balance
        --     SELECT p.public_key, dbo.get_balance(p.public_key) , p.utxo
        --     FROM Parties p 
        --     WHERE p.tx_id = Transactions.tx_id -- Match each transaction to its parties
        --         AND dbo.confirmed_balance(p.public_key) + p.utxo < 0  -- Exclude if results in a negative balance 
        -- );
        
    SELECT @all_tx_hashes = 
        STRING_AGG(CAST(tx_hash AS CHAR(32)), '') WITHIN GROUP (ORDER BY tx_id)
    FROM Transactions
    WHERE block_id = @block_id; 

    SELECT @block_fees = -COALESCE(SUM(p.utxo), 0) 
    FROM Transactions t INNER JOIN Parties p 
         ON p.tx_id = t.tx_id
    WHERE t.block_id = @block_id;

    SELECT @block_reward = CONVERT(BIGINT,VariableValue)
    FROM Parameters WHERE VariableName = 'block_reward';
    
    SET @coinbase_reward = @block_fees +  @block_reward;

    EXEC new_transaction @coinbase_tx_id OUTPUT; 

    -- Add only one Party record for the coinbase transaction for the miner.
    INSERT INTO Parties (tx_id, public_key, utxo, signature)
        VALUES (@coinbase_tx_id, @miner, @coinbase_reward, NULL);

    SET @tx_hash = HASHBYTES('SHA2_256', 
                CONCAT(CAST(@miner AS CHAR(32)) + 
                            CAST(@coinbase_reward AS CHAR(20)) + 
                            '0'));

    -- Close the coinbase transaction with the calculated hash. Cannot use the close_transaction procedure. 
    UPDATE Transactions
    SET tx_hash = @tx_hash,
        block_id = @block_id
    WHERE tx_id = @coinbase_tx_id; 

    -- Simplified Merkel Tree: Concatenate all closed transaction hashes for the block.
    SET @merkle_root = HASHBYTES('SHA2_256', CONCAT(@all_tx_hashes, @tx_hash)); 

    SELECT @version = CONVERT(INT,VariableValue)
    FROM Parameters WHERE VariableName = 'version';
    SELECT @bits = CONVERT(INT,VariableValue)
    FROM Parameters WHERE VariableName = 'bits';
    SELECT @target = CONVERT(BINARY(32),VariableValue)
    FROM Parameters WHERE VariableName = 'target'; 

    -- Calculate the hash of the combined block data using SHA256. 
    SET @block_hash = 
            HASHBYTES('SHA2_256', HASHBYTES('SHA2_256', 
            CONCAT(
                CAST(@version AS BINARY(4)),         -- 4 bytes for version as binary
                @previous_hash,                      -- 32 bytes for previous hash
                @merkle_root,                        -- 32 bytes for merkle root
                CAST(@time_stamp AS BINARY(4)),      -- 4 bytes for timestamp as binary
                CAST(@bits AS BINARY(4)),            -- 4 bytes for difficulty target (bits of zeros) as binary
                CAST(@gnonce AS BINARY(4))           -- 4 bytes for golden nonce as binary
            )
        ));

    -- Check if @block_hash meets the difficulty criterion. 
    IF @block_hash > @target
    BEGIN 
        ROLLBACK TRANSACTION; 
        THROW 51000, 'Wrong nonce! Hash does not meet the difficulty target.', 1;
    END 

    -- Close the block and complete its fields. 
    UPDATE Blocks 
    SET block_hash = @block_hash, 
        time_stamp = @time_stamp,
        miner = @miner,
        merkle_root = @merkle_root,
        nonce = @gnonce
    WHERE block_id = @block_id; 

    -- Open the next block without hash, timestamp or miner.
    INSERT INTO Blocks (previous_hash) 
        VALUES (@block_hash); 

    UPDATE Accounts
    SET balance = COALESCE(balance, 0) + @coinbase_reward
    WHERE public_key = @miner; 

    COMMIT;

    PRINT 'Block Successfully Closed. Block ID = ' + CONVERT(CHAR(20), @block_id); 
    PRINT 'Miner = ' + CONVERT(CHAR(66), @miner, 1); 
    PRINT 'Block Hash = ' + CONVERT(CHAR(66), @block_hash, 1); 
    PRINT 'Golden Nonce = ' + CONVERT(CHAR(20), @gnonce); 

    SELECT @block_id = block_id 
    FROM Blocks WHERE block_hash IS NULL; 

    PRINT 'Next Block = ' + CONVERT(CHAR(20), @block_id);
END;
GO 

CREATE TABLE Parameters (
    Run INT, 
    VariableName VARCHAR(30), 
    VariableValue SQL_VARIANT
); 

DECLARE @version INT = 1, -- Version 1 of the protocol
    @bits INT = 20, -- Requiring 16 leading zeroes for mining
    @target BINARY(32) = 0x00000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, -- POWER(2,256-@bits)-1  
    @block_reward BIGINT = 5000000000; -- Mining reward per block = 50 BTC = 5,000,000,000 SATs 

INSERT INTO Parameters (Run, VariableName, VariableValue) 
        VALUES (0, 'version', @version); 
INSERT INTO Parameters (Run, VariableName, VariableValue) 
        VALUES (0, 'bits', @bits); 
INSERT INTO Parameters (Run, VariableName, VariableValue)
        VALUES (0, 'target', @target);
INSERT INTO Parameters (Run, VariableName, VariableValue) 
        VALUES (0, 'block_reward', @block_reward); 
