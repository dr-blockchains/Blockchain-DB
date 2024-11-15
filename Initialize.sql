-- Open the Genesis block & initialize the blockchain: 
INSERT INTO Blocks (previous_hash) 
    VALUES (NULL); 

--**  The Mining procedure **
GO
CREATE OR ALTER PROCEDURE mine_block 
    @miner BINARY(32),
    @min_fee BIGINT
AS 
BEGIN 
    DECLARE @all_tx_hashes VARCHAR(MAX),
            @block_fees BIGINT,
            @block_reward BIGINT,
            @coinbase_reward BIGINT,
            @tx_hash BINARY(32),
            @merkle_root BINARY(32),
            @nonce INT, 
            @previous_hash BINARY(32),
            @block_hash BINARY(32),
            @time_stamp INT,
            @version INT,
            @bits INT,
            @target BINARY(32);

    SELECT @all_tx_hashes = 
        STRING_AGG(CAST(tx_hash AS CHAR(32)), '') WITHIN GROUP (ORDER BY tx_id)
    FROM Transactions
    WHERE block_id IS NULL
            AND tx_hash IS NOT NULL
            AND tx_fee >= @min_fee
            -- AND NOT EXISTS (  -- Exclude transactions resulting in a negative balance
            --     SELECT 1 
            --     FROM Parties p 
            --     WHERE p.tx_id = Transactions.tx_id -- Match each transaction to its parties
            --         AND dbo.confirmed_balance(p.public_key) + p.utxo < 0);  -- Exclude if results in a negative balance for anyone

    SELECT @block_fees = -COALESCE(SUM(p.utxo), 0) 
    FROM Transactions t INNER JOIN Parties p 
         ON p.tx_id = t.tx_id
    WHERE block_id IS NULL
            AND tx_hash IS NOT NULL
            AND tx_fee >= @min_fee
            -- AND NOT EXISTS (  -- Exclude transactions resulting in a negative balance
            --     SELECT 1 
            --     FROM Parties p 
            --     WHERE p.tx_id = Transactions.tx_id -- Match each transaction to its parties
            --         AND dbo.confirmed_balance(p.public_key) + p.utxo < 0);  -- Exclude if results in a negative balance for anyone

    INSERT INTO Parameters (Run, VariableName, VariableValue) 
        VALUES (6, 'Len:all_tx_hashes ', LEN(@all_tx_hashes)); 

    SELECT @block_reward = CONVERT(BIGINT,VariableValue)
    FROM Parameters WHERE VariableName = 'block_reward';

    SET @coinbase_reward = @block_fees + @block_reward;

    -- The coinbase transaction 
    SET @tx_hash = HASHBYTES('SHA2_256', 
                CONCAT(CAST(@miner AS CHAR(32)) + 
                            CAST(@coinbase_reward AS CHAR(20)) + 
                            '0'));
    INSERT INTO Parameters (Run, VariableName, VariableValue) 
        VALUES (6, 'tx_hash', @tx_hash); 

    -- Simplified Merkel Tree: Concatenate all closed transaction hashes for the block.
    SET @merkle_root = HASHBYTES('SHA2_256', CONCAT(@all_tx_hashes, @tx_hash)); 

    INSERT INTO Parameters (Run, VariableName, VariableValue) 
        VALUES (6, 'concat', CONCAT(@all_tx_hashes, CAST(@tx_hash AS CHAR(64)))); 
    INSERT INTO Parameters (Run, VariableName, VariableValue) 
        VALUES (6, 'Len:concat', LEN(CONCAT(@all_tx_hashes, CAST(@tx_hash AS CHAR(64))))); 
    INSERT INTO Parameters (Run, VariableName, VariableValue) 
        VALUES (6, 'merkle_root', @merkle_root); 

    SELECT @previous_hash = previous_hash 
    FROM Blocks
    WHERE block_hash IS NULL;

    SET @time_stamp = DATEDIFF(SECOND, '1970-01-01', GETUTCDATE());
    SELECT @version = CONVERT(INT,VariableValue)
    FROM Parameters WHERE VariableName = 'version';
    SELECT @bits = CONVERT(INT,VariableValue)
    FROM Parameters WHERE VariableName = 'bits';
    SELECT @target = CONVERT(BINARY(32),VariableValue)
    FROM Parameters WHERE VariableName = 'target';
    SET @block_hash = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    SET @nonce = 0;

    WHILE @block_hash > @target
    BEGIN
        SET @nonce = @nonce + 1 ;
        SET @block_hash = 
            HASHBYTES('SHA2_256', HASHBYTES('SHA2_256', 
            CONCAT(
                CAST(@version AS BINARY(4)),         -- 4 bytes for version as binary
                @previous_hash,                      -- 32 bytes for previous hash
                @merkle_root,                        -- 32 bytes for merkle root
                CAST(@time_stamp AS BINARY(4)),      -- 4 bytes for timestamp as binary
                CAST(@bits AS BINARY(4)),            -- 4 bytes for difficulty target (bits of zeros) as binary
                CAST(@nonce AS BINARY(4))            -- 4 bytes for nonce as binary
            )
        ));

    END;                                  

    INSERT INTO Parameters (Run, VariableName, VariableValue) 
        VALUES (6, 'Valid nonce', @nonce);
    INSERT INTO Parameters (Run, VariableName, VariableValue) 
        VALUES (6, 'Valid block_hash', @block_hash);    

    EXEC close_block 
        @time_stamp = @time_stamp, 
        @miner = @miner, 
        @min_fee = @min_fee, 
        @gnonce = @nonce
END;
GO 

--************************************
-- Insert Satoshi's test public key first
DECLARE @satoshi BINARY(32) = HASHBYTES('SHA2_256', 'Satoshi');

INSERT INTO Accounts (public_key) 
    VALUES (@satoshi);

-- Mining the first block (block 0)
EXEC mine_block 
    @miner =  @satoshi,
    @min_fee = 0;

GO

SELECT * FROM Blocks;