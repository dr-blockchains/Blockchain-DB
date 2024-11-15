DECLARE @satoshi BINARY(32); 
SELECT TOP 1 @satoshi = public_key 
FROM Accounts 
WHERE balance > 0 
ORDER BY balance DESC;

IF @satoshi IS NULL
BEGIN
    PRINT 'Run Initialize First.';
    THROW 51000, 'No initial account with positive balance!', 1;
END;

-- Insert 10 test public keys directly into Accounts
INSERT INTO Accounts (public_key)
VALUES 
    (HASHBYTES('SHA2_256', '1')),
    (HASHBYTES('SHA2_256', '2')),
    (HASHBYTES('SHA2_256', '3')),
    (HASHBYTES('SHA2_256', '4')),
    (HASHBYTES('SHA2_256', '5')),
    (HASHBYTES('SHA2_256', '6')),
    (HASHBYTES('SHA2_256', '7'));

-- Store keys in variables for easy reference
DECLARE @alice BINARY(32) = HASHBYTES('SHA2_256', '1'),
        @bob BINARY(32) = HASHBYTES('SHA2_256', '2'),
        @charlie BINARY(32) = HASHBYTES('SHA2_256', '3'),
        @dave BINARY(32) = HASHBYTES('SHA2_256', '4'),
        @eve BINARY(32) = HASHBYTES('SHA2_256', '5'),
        @frank BINARY(32) = HASHBYTES('SHA2_256', '6'),
        @grace BINARY(32) = HASHBYTES('SHA2_256', '7');


DECLARE @tx_id INT;

--***************************** BLOCK 111111111111111111111111111111111111111111111111111111
-- TX1: Initial distribution transaction (TX1)
EXEC new_transaction @tx_id OUTPUT;
INSERT INTO Parties (tx_id, public_key, utxo, signature)
VALUES 
    (@tx_id, @satoshi, -1000, HASHBYTES('SHA2_256', 'satoshi-signature')),  -- 900 SAT Sent
    (@tx_id, @alice, 700, NULL),  -- 700 SAT received
    (@tx_id, @bob, 200, NULL),    -- 200 SAT received
    (@tx_id, @charlie, 100, NULL) -- 100 SAT received 
    -- Fee = 0
EXEC close_transaction @tx_id;
-- satoshi:10 , alice:10 , bob:20 , charlie:10 

-- Mining the open block 
EXEC mine_block 
    @miner = @dave, 
    @min_fee = 0;  --> TX1 (0)
-- Confirmed: satoshi:4999999000 , alice:700 , bob:200 , charlie:100 , dave:5000000000 

--***************************** BLOCK 222222222222222222222222222222222222222222222222222222
EXEC mine_block 
    @miner = @eve,
    @min_fee = 10; -- No transaction!
-- Confirmed: satoshi:4999999000 , alice:700 , bob:200 , charlie:100 , dave:5000000000 , eve:5000000000

--***************************** BLOCK 3333333333333333333333333333333333333333333333333333333
-- TX2
EXEC new_transaction @tx_id OUTPUT;
INSERT INTO Parties (tx_id, public_key, utxo, signature)
VALUES 
    (@tx_id, @alice, -200, HASHBYTES('SHA2_256', 'alicesig')), 
    (@tx_id, @bob, 150, NULL); 
    -- Fee = 50 SAT
EXEC close_transaction @tx_id;
-- satoshi:4999999000 , alice:500 , bob:350 , charlie:100 , dave:5000000000 , eve:5000000000

-- TX3
EXEC new_transaction @tx_id OUTPUT; 
INSERT INTO Parties (tx_id, public_key, utxo, signature)
VALUES 
    (@tx_id, @bob, -300, HASHBYTES('SHA2_256', 'bobsig')), 
    (@tx_id, @charlie, -100, HASHBYTES('SHA2_256', 'charliesig')), 
    (@tx_id, @dave, 350, NULL); 
    -- Fee = 50 SAT
EXEC close_transaction @tx_id; 
-- satoshi:4999999000 , alice:500 , bob:50 , charlie:0 , dave:5000000350 , eve:5000000000

-- TX4
EXEC new_transaction @tx_id OUTPUT;
INSERT INTO Parties (tx_id, public_key, utxo, signature)
VALUES 
    (@tx_id, @satoshi, -900, HASHBYTES('SHA2_256', 'evesig')), 
    (@tx_id, @frank, 890, NULL);  
    -- Fee = 10 SAT
EXEC close_transaction @tx_id;
-- satoshi:4999998100 , alice:500 , bob:50 , charlie:0 , dave:5000000350 , eve:5000000000 , frank:890

EXEC mine_block 
    @miner = @alice, 
    @min_fee = 20; --> TX2(50), TX3(50), NOT TX4(10) = 100 SAT
-- Confirmed: satoshi:4999999000 , alice:5000000600 , bob:50 , charlie:0 , dave:5000000350 , eve:5000000000 , frank:0

--***************************** BLOCK 4444444444444444444444444444444444444444444444444444444444444444444444
EXEC mine_block 
    @miner = @frank, 
    @min_fee = 10; --> TX4(10) 
-- Confirmed: satoshi:4999998100 , alice:5000000600 , bob:50 , charlie:0 , dave:5000000350 , eve:5000000000 , frank:5000000900

--***************************** BLOCK 5555555555555555555555555555555555555555555555555555555555555555555555
-- TX5
EXEC new_transaction @tx_id OUTPUT;
INSERT INTO Parties (tx_id, public_key, utxo, signature)
VALUES 
    (@tx_id, @frank, -4000, HASHBYTES('SHA2_256', 'franksig')),  
    (@tx_id, @eve, 5000, NULL);  
    -- Fee = -1000 SAT < 0
EXEC close_transaction @tx_id; 
--> INVALID TRANSACTION! Inputs must be larger than or equal to the outputs.

-- TX6
EXEC new_transaction @tx_id OUTPUT; 
INSERT INTO Parties (tx_id, public_key, utxo, signature)
VALUES 
    (@tx_id, @charlie, -200, HASHBYTES('SHA2_256', 'alicesig')), 
    (@tx_id, @bob, 100, NULL);  
    -- Fee = 100 SAT
EXEC close_transaction @tx_id;
--> INVALID TRANSACTION! Sender does not have enough balance. 

-- TX7
EXEC new_transaction @tx_id OUTPUT; 
INSERT INTO Parties (tx_id, public_key, utxo, signature)
VALUES 
    (@tx_id, @alice, -200, HASHBYTES('SHA2_256', 'alicesig')), 
    (@tx_id, @bob, 100, NULL);  
    -- Fee = 100 SAT
EXEC close_transaction @tx_id;
-- Confirmed: satoshi:4999998100 , alice:5000000400 , bob:150 , charlie:0 , dave:5000000350 , eve:5000000000 , frank:5000000900

EXEC dbo.mine_block 
    @miner = @alice,
    @min_fee = 50; --> TX7(100)
-- Confirmed: satoshi:4999998100 , alice:10000000500 , bob:150 , charlie:0 , dave:5000000350 , eve:5000000000 , frank:5000000900

-- View results ******************************************************************************
SELECT * FROM Blocks;

SELECT *, dbo.transaction_fee(tx_id) AS transaction_fee
FROM Transactions;

SELECT * FROM Parties;

SELECT 
    CASE 
        WHEN public_key = HASHBYTES('SHA2_256', 'Satoshi') THEN 'Satoshi'
        WHEN public_key = HASHBYTES('SHA2_256', '1') THEN 'Alice'
        WHEN public_key = HASHBYTES('SHA2_256', '2') THEN 'Bob'
        WHEN public_key = HASHBYTES('SHA2_256', '3') THEN 'Charlie'
        WHEN public_key = HASHBYTES('SHA2_256', '4') THEN 'Dave'
        WHEN public_key = HASHBYTES('SHA2_256', '5') THEN 'Eve'
        WHEN public_key = HASHBYTES('SHA2_256', '6') THEN 'Frank'
        WHEN public_key = HASHBYTES('SHA2_256', '7') THEN 'Grace'
        ELSE 'Unknown'
    END AS account_name,
    CONVERT(CHAR(64), public_key, 1) AS public_key,
    balance AS table_balance,
    dbo.confirmed_balance(public_key) AS confirmed_balance,
    created_at
FROM Accounts
ORDER BY balance DESC; 