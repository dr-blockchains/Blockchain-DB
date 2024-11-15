DROP PROCEDURE IF EXISTS dbo.mine_block;
DROP PROCEDURE IF EXISTS dbo.close_block;
DROP PROCEDURE IF EXISTS dbo.close_transaction;
DROP PROCEDURE IF EXISTS dbo.new_transaction;

DROP FUNCTION IF EXISTS dbo.get_balance;
DROP FUNCTION IF EXISTS dbo.transaction_fee;

DROP TRIGGER IF EXISTS dbo.protect_parties;
DROP TRIGGER IF EXISTS dbo.protect_closed_transactions;

DROP TABLE IF EXISTS dbo.Parties;
DROP TABLE IF EXISTS dbo.Transactions;
DROP TABLE IF EXISTS dbo.Blocks;
DROP TABLE IF EXISTS dbo.Accounts;

DROP TABLE IF EXISTS dbo.Parameters;

-- USE master;
-- ALTER DATABASE BlockchainDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
-- DROP DATABASE BlockchainDB;
-- CREATE DATABASE BlockchainDB;