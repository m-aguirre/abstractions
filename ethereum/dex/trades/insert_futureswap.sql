CREATE OR REPLACE FUNCTION dex.insert_futureswap(start_ts timestamptz, end_ts timestamptz=now(), start_block numeric=0, end_block numeric=9e18) RETURNS integer
LANGUAGE plpgsql AS $function$
DECLARE r integer;
BEGIN
WITH rows AS (
  INSERT INTO dex.trades (
      block_time,
      token_a_symbol,
      token_b_symbol,
      token_a_amount,
      token_b_amount,
      project,
      version,
      category,
      trader_a,
      trader_b,
      token_a_amount_raw,
      token_b_amount_raw,
      usd_amount,
      token_a_address,
      token_b_address,
      exchange_contract_address,
      tx_hash,
      tx_from,
      tx_to,
      trace_address,
      evt_index,
      trade_id
  )
  SELECT
      dexs.block_time,
      erc20a.symbol AS token_a_symbol,
      erc20b.symbol AS token_b_symbol,
      token_a_amount_raw AS token_a_amount,
      token_b_amount_raw AS token_b_amount,
      project,
      version,
      category,
      coalesce(trader_a, tx."from") as trader_a, -- subqueries rely on this COALESCE to avoid redundant joins with the transactions table
      trader_b,
      token_a_amount_raw,
      token_b_amount_raw,
      coalesce(
          usd_amount,
          (token_a_amount_raw + token_b_amount_raw)
      ) AS usd_amount,
      token_a_address,
      token_b_address,
      exchange_contract_address,
      tx_hash,
      tx."from" as tx_from,
      tx."to" as tx_to,
      trace_address,
      evt_index,
      row_number() OVER (PARTITION BY tx_hash, evt_index, trace_address) AS trade_id
    FROM (
  --Futureswap
  SELECT
    a.evt_block_time as block_time,
    'Futureswap' AS project,
    '1' AS version,
    'DEX' AS category,
    a.trader AS trader_a,
    NULL::bytea AS trader_b,
    b.token_a_amount_raw AS token_a_amount_raw,
    a.token_b_amount_raw AS token_b_amount_raw,
    NULL::numeric AS usd_amount,
    b.contract_address::bytea AS token_a_address,
    a.contract_address::bytea AS token_b_address,
    b.contract_address::bytea AS exchange_contract_address,
    a.evt_tx_hash AS tx_hash,
    NULL::integer[] AS trace_address,
    a.evt_index
    FROM (
      SELECT ("assetMarketPrice"/1e18) * ("assetRedemptionAmount"/1e18) AS token_b_amount_raw, "tradeId", trader, evt_block_time, contract_address, evt_tx_hash, evt_index
      FROM futureswap."FS_ETH_USDC_evt_TradeClose"
    ) a
    JOIN
      (SELECT (leverage) * (collateral/1e18) AS token_a_amount_raw, "tradeId", contract_address
      FROM futureswap."FS_ETH_USDC_evt_TradeOpen"
    ) b ON a."tradeId" = b."tradeId"
    ) dexs

    INNER JOIN ethereum.transactions tx
        ON dexs.tx_hash = tx.hash
        AND tx.block_time >= start_ts
        AND tx.block_time < end_ts
        AND tx.block_number >= start_block
        AND tx.block_number < end_block
    LEFT JOIN erc20.tokens erc20a ON erc20a.contract_address = dexs.token_a_address
    LEFT JOIN erc20.tokens erc20b ON erc20b.contract_address = dexs.token_b_address
    LEFT JOIN prices.usd pa ON pa.minute = date_trunc('minute', dexs.block_time)
        AND pa.contract_address = dexs.token_a_address
        AND pa.minute >= start_ts
        AND pa.minute < end_ts
    LEFT JOIN prices.usd pb ON pb.minute = date_trunc('minute', dexs.block_time)
        AND pb.contract_address = dexs.token_b_address
        AND pb.minute >= start_ts
        AND pb.minute < end_ts
    WHERE dexs.block_time >= start_ts
    AND dexs.block_time < end_ts

    ON CONFLICT DO NOTHING
    RETURNING 1
)
SELECT count(*) INTO r from rows;
RETURN r;
END
$function$;


-- fill 2020
SELECT dex.insert_futureswap(
    '2020-01-01',
    '2021-01-01',
    (SELECT max(number) FROM ethereum.blocks WHERE time < '2020-01-01'),
    (SELECT max(number) FROM ethereum.blocks WHERE time <= '2021-01-01')
)
WHERE NOT EXISTS (
    SELECT *
    FROM dex.trades
    WHERE block_time > '2020-01-01'
    AND block_time <= '2021-01-01'
    AND project = 'Futureswap'
);

-- fill 2021
SELECT dex.insert_futureswap(
    '2021-01-01',
    now(),
    (SELECT max(number) FROM ethereum.blocks WHERE time < '2021-01-01'),
    (SELECT max(number) FROM ethereum.blocks)
)
WHERE NOT EXISTS (
    SELECT *
    FROM dex.trades
    WHERE block_time > '2021-01-01'
    AND block_time <= now()
    AND project = 'Futureswap'
);

INSERT INTO cron.job (schedule, command)
VALUES ('*/12 * * * *', $$
    SELECT dex.insert_futureswap(
        (SELECT max(block_time) - interval '1 days' FROM dex.trades WHERE project='Futureswap'),
        (SELECT now()),
        (SELECT max(number) FROM ethereum.blocks WHERE time < (SELECT max(block_time) - interval '1 days' FROM dex.trades WHERE project='Futureswap')),
        (SELECT MAX(number) FROM ethereum.blocks));
$$)
ON CONFLICT (command) DO UPDATE SET schedule=EXCLUDED.schedule;
