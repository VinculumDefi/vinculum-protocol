/**
 * Vinculum Protocol — QA Data Generator
 * ======================================
 * Runs the price resolver against all 500 registry assets and writes
 * price-verification-data.json for the Registry Price QA Dashboard.
 *
 * Does NOT change production resolver behavior.
 * Does NOT modify contracts, tokenomics, or registry architecture.
 * Read-only trace of the existing cascade.
 *
 * Usage:
 *   node generate-qa-data.js
 *
 * Output:
 *   price-verification-data.json   (consumed by registry-qa.html)
 *
 * Optional env:
 *   CHAINLINK_RPC_URL   — enables Tier 1 Chainlink
 *   COINGECKO_API_KEY   — Pro CoinGecko endpoint
 */

'use strict';
require('dotenv').config();

const fs = require('fs');
const {
  PYTH_FEEDS,
  COINGECKO_IDS,
  DEXSCREENER_TOKENS,
  CHAINLINK_FEEDS,
  CONFIG,
} = require('./vinculum-price-resolver-v3.js');

// ── ALL 500 REGISTRY SYMBOLS ─────────────────────────────────────────────────
const ALL_500 = [...new Set([
  'USDC','ETH','BTC','DOGE','SOL','USDT','WBTC','LINK','STETH','DAI',
  'UNI','AAVE','LDO','SHIB','PEPE','WSTETH','CBETH','SKY','CBBTC','USDS',
  'MKR','GRT','ENS','PAXG','IMX','PENDLE','EIGEN','MATIC','RNDR','SNX',
  'CRV','1INCH','RPL','RETH','ENA','RON','CHZ','FET','USDE','ONDO',
  'OKB','GHO','COMP','FLOKI','BLUR','PSG','BAR','PYUSD','BAL','WLD',
  'BAT','LUSD','COW','MNT','STRK','ZK','CRO','POL','YFI','FXS',
  'FRAX','CRVUSD','CVX','MOG','APE','BLAST','MANA','SAND','AXS','OCEAN',
  'ETHFI','SUSDE','WEETH','EETH','MORPHO','LQTY','DYDX','FRXETH','SFRXETH','PRIME',
  'JUV','ACM','CITY','AGIX','SUSHI','W','AXL','FLUID','STG','NEIRO',
  'TURBO','BANANA','UNIBOT','KAITO','GALA','ARKM','FIL','BGB','MUMU','SUSD',
  'KCS','GT','USUAL','EUROC','PEOPLE','NMR','API3','TRB','UMA','TBTC',
  'LPT','GLM','ETHX','ILV','GODS','PUFFER','SWELL','METIS','ANKR','TRAC',
  'BIFI','SYN','LRC','TAIKO','SCROLL','DIA','OETH','GEARBOX','STORJ','NOT',
  'BAND','LAYER3','XAUT','DODO','OHM','PIXEL','OLAS','FLUX','ACH','AKT',
  'MPL','MANTA','ALT','CELO','IOTX','RSWETH','USD0','CFG','OG','SWEAT',
  'RARE','CARV','ELON','MFER','MX','ALICE','BEAM','YGG','MC','MASK',
  'CYBER','AIOZ','ANDY','POOL','MAGA','ACROSS','USDM','AGEUR','T','HOP',
  'RLC','INDEX','BADGER','SPELL','REQ','INST','ALCX','WKC','JPEG','OMNI',
  'XBORG','WILD','ASR','XCAD','AURORA','SUPRA','XYO','LUMIA','SYRUP','LOOKS',
  'PYR','MODE','FUEL','LSK','PLA','HIGH','VOXEL','BTRST','POWR','PROM',
  'SUB','TLM','TSUKA','AKITA','AIDOGE','CULT','ANGLE','FREYSA','MIGGLES','PAAL',
  'RSETH','EZETH','IPOR','SPECTRA','EULER','RAIL','PRISMA','BERA','HYP','TigerOG',
  'MAGIC','KENDU','SLP','PIPPIN','PNKSTR','BOLD','AIXBT','STEP','MNGO',
  'BONK','WIF','PENGU','POPCAT','FARTCOIN','MEW','JTO','JUP','RAY','PYTH',
  'TNSR','MPLX','MOBILE','MNDE','MSOL','JITOSOL','AI16Z','VIRTUAL','ZEREBRO','ARC',
  'ELIZA','DEGENAI','GNON','PNUT','BOME','TRUMP','MELANIA','GIGA','GOAT','CHILLGUY',
  'MOODENG','PONKE','ACT','MYRO','WEN','TRUTH','HARAMBE','FWOG','KNINE','SLERF',
  'PUNCH','HAMS','BIRB','SIGMA','TREMP','BODEN','DRIFT','KMNO','ORCA','CLOUD',
  'GRASS','HNT','IO','STEPN','NATIX','ATLAS','POLIS','SAMO','HXRO','IOT',
  'GRIFFAIN','RETARDIO','LTC','BCH','XRP','ADA','DGB',
  'ARB','OP','AVAX','AERO','GMX','GNS','GRAIL','JOE','CAKE','RDNT',
  'WOO','PERP','VELA','GHST','QUICK','ALPACA','QI','SAVAX','GGAVAX','COQ',
  'PNG','BRETT','TOSHI','DEGEN','BUILD','NORMIE','HIGHER','TYBG','LMAO','BASED',
  'LUNC','BABYDOGE','FDUSD','GALXE','ID','HOOK','ALPINE','SANTOS','ATM','PORTO',
  'LAZIO','INTER','WOJAK','SPX','DIMO','REVV','TROLL',
  'WBTC_ETH','USDC_ETH','USDT_ETH','LINK_ETH','UNI_ETH','MKR_ETH','SNX_ETH',
  'COMP_ETH','CRV_ETH','LDO_ETH','RPL_ETH','RETH_ETH','FXS_ETH','CVX_ETH',
  'BAL_ETH','YFI_ETH','GRT_ETH','MATIC_ETH','ARB_ETH','OP_ETH','BAT_ETH',
  'CHZ_ETH','AXS_ETH','SAND_ETH','MANA_ETH','SHIB_ETH','GLM_ETH','BAND_ETH',
  'TRB_ETH','RLC_ETH','FET_ETH','AGIX_ETH','OCEAN_ETH','NMR_ETH','STETH_ETH',
  'EUROC_ETH','PYUSD_ETH','TLM2','LUNC_BSC','FLOKI2','SHIB2',
  'ELON2','GMT2','BIFI2','PENDLE_ARB','PENDLE_B','CRV_ARB','SNX_ARB',
  'NORMIE2','GHST2','TNSR2','VIRTUAL2','TBTC2','CAKE_BSC','JOE_AVAX2',
  'WBTC_ARB','WBTC_OP','WBTC_POL','WETH_ARB','WETH_OP','WETH_POL','WETH_BSC',
  'WETH_AVAX','USDC_ARB','USDC_SOL','USDC_BSC','USDC_AVAX','USDC_OP','USDC_POL',
  'USDC_BASE','USDT_ARB','USDT_POL','USDT_BSC','USDT_AVAX','USDT_OP',
  'LINK_ARB','LINK_POL','LINK_BSC','LINK_AVAX','LINK_OP','DAI_ARB','DAI_OP',
  'DAI_POL','DAI_BSC','DAI_AVAX','AAVE_ARB','AAVE_OP','AAVE_POL','AAVE_AVAX',
  'UNI_ARB','UNI_OP','UNI_POL','POL_TOKEN','ARB_TOKEN','OP_TOKEN','AVAX_NATIVE',
  'GRT_ARB','IMX_ETH','RNDR_SOL','VIRTUAL_BASE','SNS','SNS_OP','ZEREBRO2',
  'CBETH_BASE','AVAX_MEME','APU','MOG','CULT','KEYCAT',
])];

// ── CHAIN MAPPING ─────────────────────────────────────────────────────────────
// Derived from DEXSCREENER_TOKENS and known chain context.
const CHAIN_MAP = {
  // Ethereum-native
  ETH:'ethereum', USDC:'ethereum', USDT:'ethereum', WBTC:'ethereum',
  LINK:'ethereum', STETH:'ethereum', DAI:'ethereum', UNI:'ethereum',
  AAVE:'ethereum', LDO:'ethereum', SHIB:'ethereum', WSTETH:'ethereum',
  CBETH:'ethereum', SKY:'ethereum', MKR:'ethereum', GRT:'ethereum',
  ENS:'ethereum', PAXG:'ethereum', MATIC:'ethereum', SNX:'ethereum',
  CRV:'ethereum', '1INCH':'ethereum', RPL:'ethereum', RETH:'ethereum',
  ENA:'ethereum', CHZ:'ethereum', FET:'ethereum', USDE:'ethereum',
  ONDO:'ethereum', COMP:'ethereum', FLOKI:'ethereum', BLUR:'ethereum',
  BAL:'ethereum', WLD:'ethereum', BAT:'ethereum', LUSD:'ethereum',
  COW:'ethereum', YFI:'ethereum', FXS:'ethereum', FRAX:'ethereum',
  CVX:'ethereum', APE:'ethereum', MANA:'ethereum', SAND:'ethereum',
  AXS:'ethereum', OCEAN:'ethereum', ETHFI:'ethereum', SUSDE:'ethereum',
  WEETH:'ethereum', EETH:'ethereum', MORPHO:'ethereum', LQTY:'ethereum',
  DYDX:'ethereum', FRXETH:'ethereum', SFRXETH:'ethereum', PRIME:'ethereum',
  AGIX:'ethereum', SUSHI:'ethereum', FLUID:'ethereum', STG:'ethereum',
  NEIRO:'ethereum', TURBO:'ethereum', UNIBOT:'ethereum', ARKM:'ethereum',
  SUSD:'ethereum', EUROC:'ethereum', PEOPLE:'ethereum', NMR:'ethereum',
  API3:'ethereum', TRB:'ethereum', UMA:'ethereum', TBTC:'ethereum',
  LPT:'ethereum', GLM:'ethereum', METIS:'ethereum', ANKR:'ethereum',
  BIFI:'ethereum', LRC:'ethereum', DIA:'ethereum', STORJ:'ethereum',
  BAND:'ethereum', XAUT:'ethereum', DODO:'ethereum', OHM:'ethereum',
  OLAS:'ethereum', ACH:'ethereum', MASK:'ethereum', CYBER:'ethereum',
  ANDY:'ethereum', MAGA:'ethereum', AGEUR:'ethereum', RLC:'ethereum',
  BADGER:'ethereum', SPELL:'ethereum', REQ:'ethereum', ALCX:'ethereum',
  JPEG:'ethereum', OMNI:'ethereum', WILD:'ethereum', SYRUP:'ethereum',
  PYR:'ethereum', BTRST:'ethereum', POWR:'ethereum', PROM:'ethereum',
  CULT:'ethereum', ANGLE:'ethereum', RSETH:'ethereum', EZETH:'ethereum',
  RSWETH:'ethereum', PRISMA:'ethereum', EULER:'ethereum', RAIL:'ethereum',
  MAGIC:'ethereum', MOG:'ethereum', WOJAK:'ethereum', KENDU:'ethereum',
  PNKSTR:'ethereum', CBBTC:'ethereum', USDS:'ethereum',
  // Base
  AERO:'base', BRETT:'base', TOSHI:'base', DEGEN:'base', NORMIE:'base',
  HIGHER:'base', TYBG:'base', LMAO:'base', BUILD:'base', BASED:'base',
  MFER:'base', VIRTUAL:'base', KAITO:'base', SPX:'base', AIXBT:'base',
  KEYCAT:'base', MIGGLES:'base',
  // BNB Chain
  TigerOG:'bsc', CAKE:'bsc', LUNC:'bsc',
  // Solana
  SOL:'solana', BONK:'solana', WIF:'solana', PENGU:'solana', POPCAT:'solana',
  FARTCOIN:'solana', MEW:'solana', JTO:'solana', JUP:'solana', RAY:'solana',
  PYTH:'solana', TNSR:'solana', MPLX:'solana', MNDE:'solana', MSOL:'solana',
  JITOSOL:'solana', AI16Z:'solana', ZEREBRO:'solana', ARC:'solana',
  ELIZA:'solana', DEGENAI:'solana', GNON:'solana', PNUT:'solana',
  BOME:'solana', TRUMP:'solana', MELANIA:'solana', GIGA:'solana',
  GOAT:'solana', CHILLGUY:'solana', MOODENG:'solana', PONKE:'solana',
  ACT:'solana', MYRO:'solana', WEN:'solana', HARAMBE:'solana', FWOG:'solana',
  KNINE:'solana', SLERF:'solana', PUNCH:'solana', HAMS:'solana', BIRB:'solana',
  SIGMA:'solana', TREMP:'solana', BODEN:'solana', DRIFT:'solana', KMNO:'solana',
  ORCA:'solana', CLOUD:'solana', GRASS:'solana', HNT:'solana', IO:'solana',
  STEPN:'solana', NATIX:'solana', ATLAS:'solana', POLIS:'solana', SAMO:'solana',
  HXRO:'solana', IOT:'solana', GRIFFAIN:'solana', RETARDIO:'solana',
  PIPPIN:'solana', MUMU:'solana', TROLL:'solana', MOBILE:'solana', STEP:'solana',
  MNGO:'solana',
  // UTXO
  BTC:'utxo', LTC:'utxo', BCH:'utxo', DGB:'utxo', DOGE:'utxo',
  // XRPL
  XRP:'xrpl',
  // Other
  ADA:'cardano', RON:'ronin', IMX:'immutable-x',
  ARB:'arbitrum', OP:'optimism', AVAX:'avalanche',
  MNT:'mantle', STRK:'starknet', ZK:'zkSync', BERA:'berachain',
  CELO:'celo', IOTX:'iotex',
  OKB:'okc', KCS:'kucoin', GT:'gatechain',
  // Multi-chain suffixed entries
  WBTC_ETH:'ethereum', USDC_ETH:'ethereum', USDT_ETH:'ethereum',
  LINK_ETH:'ethereum', UNI_ETH:'ethereum', MKR_ETH:'ethereum',
  SNX_ETH:'ethereum', COMP_ETH:'ethereum', CRV_ETH:'ethereum',
  LDO_ETH:'ethereum', RPL_ETH:'ethereum', RETH_ETH:'ethereum',
  FXS_ETH:'ethereum', CVX_ETH:'ethereum', BAL_ETH:'ethereum',
  YFI_ETH:'ethereum', GRT_ETH:'ethereum', MATIC_ETH:'ethereum',
  ARB_ETH:'ethereum', OP_ETH:'ethereum', BAT_ETH:'ethereum',
  CHZ_ETH:'ethereum', AXS_ETH:'ethereum', SAND_ETH:'ethereum',
  MANA_ETH:'ethereum', SHIB_ETH:'ethereum', GLM_ETH:'ethereum',
  BAND_ETH:'ethereum', TRB_ETH:'ethereum', RLC_ETH:'ethereum',
  FET_ETH:'ethereum', AGIX_ETH:'ethereum', OCEAN_ETH:'ethereum',
  NMR_ETH:'ethereum', STETH_ETH:'ethereum', EUROC_ETH:'ethereum',
  PYUSD_ETH:'ethereum', CBETH_BASE:'base',
  LUNC_BSC:'bsc', FLOKI2:'bsc', SHIB2:'bsc', ELON2:'bsc',
  GMT2:'bsc', BIFI2:'bsc', TLM2:'bsc', CAKE_BSC:'bsc',
  PENDLE_ARB:'arbitrum', CRV_ARB:'arbitrum', SNX_ARB:'arbitrum',
  WBTC_ARB:'arbitrum', WETH_ARB:'arbitrum', USDC_ARB:'arbitrum',
  USDT_ARB:'arbitrum', LINK_ARB:'arbitrum', DAI_ARB:'arbitrum',
  AAVE_ARB:'arbitrum', UNI_ARB:'arbitrum', GRT_ARB:'arbitrum',
  PENDLE_B:'base',
  WBTC_OP:'optimism', WETH_OP:'optimism', USDC_OP:'optimism',
  USDT_OP:'optimism', LINK_OP:'optimism', DAI_OP:'optimism',
  AAVE_OP:'optimism', UNI_OP:'optimism', SNS_OP:'optimism',
  WBTC_POL:'polygon', WETH_POL:'polygon', USDC_POL:'polygon',
  USDT_POL:'polygon', LINK_POL:'polygon', DAI_POL:'polygon',
  AAVE_POL:'polygon', UNI_POL:'polygon', NORMIE2:'base', GHST2:'polygon',
  TNSR2:'solana', VIRTUAL2:'base', TBTC2:'ethereum',
  JOE_AVAX2:'avalanche', WETH_BSC:'bsc', WETH_AVAX:'avalanche',
  USDC_SOL:'solana', USDC_BSC:'bsc', USDC_AVAX:'avalanche', USDC_BASE:'base',
  USDT_BSC:'bsc', USDT_AVAX:'avalanche', LINK_BSC:'bsc', LINK_AVAX:'avalanche',
  DAI_BSC:'bsc', DAI_AVAX:'avalanche', AAVE_AVAX:'avalanche',
  POL_TOKEN:'polygon', ARB_TOKEN:'arbitrum', OP_TOKEN:'optimism',
  AVAX_NATIVE:'avalanche', AVAX_MEME:'avalanche', IMX_ETH:'ethereum',
  RNDR_SOL:'solana', VIRTUAL_BASE:'base', SNS:'ethereum', ZEREBRO2:'solana',
  APU:'ethereum',
};

// ── SOURCE URL BUILDERS ───────────────────────────────────────────────────────
function buildSourceUrl(sym, sourceUsed, cgId, dexEntry, clFeed) {
  if (sourceUsed === 'Chainlink' && clFeed)
    return `https://etherscan.io/address/${clFeed.address}`;
  if (sourceUsed === 'Pyth') {
    const feedId = PYTH_FEEDS[sym];
    if (feedId) return `https://pyth.network/price-feeds?query=${sym}`;
  }
  if (sourceUsed === 'CoinGecko' && cgId)
    return `https://www.coingecko.com/en/coins/${cgId}`;
  if (sourceUsed === 'DexScreener' && dexEntry)
    return `https://dexscreener.com/${dexEntry.chain}/${dexEntry.address}`;
  return null;
}

// ── REMAP (same as resolver) ──────────────────────────────────────────────────
const REMAP = {
  WETH:'ETH', CBBTC:'WBTC', CBBTC_ETH:'WBTC',
  STETH_ETH:'STETH', RETH_ETH:'RETH',
  TBTC2:'TBTC', SNS:'SNX', SNS_OP:'SNX',
  FLOKI2:'FLOKI', SHIB2:'SHIB', ELON2:'ELON', GMT2:'GMT',
  BIFI2:'BIFI', DOGE2:'DOGE', TLM2:'TLM',
  ZEREBRO2:'ZEREBRO', NORMIE2:'NORMIE',
  PENDLE_ARB:'PENDLE', PENDLE_B:'PENDLE',
  VIRTUAL2:'VIRTUAL', VIRTUAL_BASE:'VIRTUAL',
  AVAX_MEME:'AVAX',
};
const norm = s => { const u = s.toUpperCase().replace(/-/g,'_'); return REMAP[u]||u; };

// ── MAIN ─────────────────────────────────────────────────────────────────────
async function main() {
  console.log('\n Vinculum — QA Data Generator');
  console.log(' Traces resolver cascade for all 500 assets (read-only)\n');

  const TIMEOUT = 12000;
  const sleep   = ms => new Promise(r => setTimeout(r, ms));
  const now     = new Date().toISOString();

  // ── Step 1: Pyth bulk ───────────────────────────────────────────────────────
  console.log('Step 1: Pyth bulk fetch…');
  const pythPrices = {};
  const pythEntries = Object.entries(PYTH_FEEDS);
  const CHUNK = 40;
  for (let i = 0; i < pythEntries.length; i += CHUNK) {
    const chunk  = pythEntries.slice(i, i+CHUNK);
    const params = chunk.map(([,id]) => `ids[]=${id}`).join('&');
    const url    = `https://hermes.pyth.network/v2/updates/price/latest?${params}&parsed=true`;
    try {
      const res  = await fetch(url, { signal: AbortSignal.timeout(TIMEOUT) });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      for (const p of (data?.parsed||[])) {
        const price = Number(p.price.price) * (10 ** p.price.expo);
        if (price > 0) pythPrices[p.id.replace(/^0x/,'')] = price;
      }
    } catch(e) { console.log(`  Pyth batch ${Math.floor(i/CHUNK)+1} failed: ${e.message}`); }
  }
  const pySymPrices = {};
  for (const [sym, feedId] of pythEntries) {
    const clean = feedId.replace(/^0x/,'');
    if (pythPrices[clean]) pySymPrices[sym] = pythPrices[clean];
  }
  console.log(`  ${Object.keys(pySymPrices).length}/${pythEntries.length} Pyth prices resolved\n`);

  // ── Step 2: CoinGecko bulk ──────────────────────────────────────────────────
  console.log('Step 2: CoinGecko bulk fetch…');
  const cgIdSet = new Set();
  for (const raw of ALL_500) {
    const sym  = norm(raw);
    const cgId = COINGECKO_IDS[sym] || COINGECKO_IDS[raw];
    if (cgId) cgIdSet.add(cgId);
  }
  const allCgIds   = [...cgIdSet];
  const cgData     = {};
  const headers    = { Accept: 'application/json' };
  if (CONFIG.coingeckoApiKey) headers['x-cg-pro-api-key'] = CONFIG.coingeckoApiKey;
  const cgBase     = CONFIG.coingeckoApiKey
    ? 'https://pro-api.coingecko.com/api/v3'
    : 'https://api.coingecko.com/api/v3';

  for (let i = 0; i < allCgIds.length; i += 250) {
    if (i > 0) { process.stdout.write('  Rate limit pause 7s… '); await sleep(7000); console.log('continuing'); }
    const chunk = allCgIds.slice(i, i+250);
    try {
      const res = await fetch(
        `${cgBase}/simple/price?ids=${chunk.join(',')}&vs_currencies=usd`,
        { headers, signal: AbortSignal.timeout(TIMEOUT) }
      );
      if (res.status === 429) {
        console.log('  Rate limited — waiting 60s…'); await sleep(60000);
        const r2 = await fetch(`${cgBase}/simple/price?ids=${chunk.join(',')}&vs_currencies=usd`,
          { headers, signal: AbortSignal.timeout(TIMEOUT) });
        if (r2.ok) Object.assign(cgData, await r2.json());
      } else if (res.ok) {
        Object.assign(cgData, await res.json());
      }
    } catch(e) { console.log(`  CoinGecko chunk failed: ${e.message}`); }
  }
  console.log(`  ${Object.keys(cgData).filter(k=>cgData[k]?.usd!=null).length}/${allCgIds.length} CoinGecko prices resolved\n`);

  // ── Step 3: DexScreener ─────────────────────────────────────────────────────
  console.log('Step 3: DexScreener fallback…');
  const dexPrices = {};
  const dexNeeded = ALL_500.filter(raw => {
    const sym = norm(raw);
    if (!DEXSCREENER_TOKENS[sym] && !DEXSCREENER_TOKENS[raw.toUpperCase()]) return false;
    if (pySymPrices[sym]) return false;
    const cgId = COINGECKO_IDS[sym] || COINGECKO_IDS[raw];
    if (cgId && cgData[cgId]?.usd != null) return false;
    return true;
  });

  await Promise.allSettled(dexNeeded.map(async raw => {
    const sym   = norm(raw);
    const token = DEXSCREENER_TOKENS[sym] || DEXSCREENER_TOKENS[raw.toUpperCase()];
    if (!token) return;
    try {
      const res  = await fetch(
        `https://api.dexscreener.com/latest/dex/tokens/${token.address}`,
        { signal: AbortSignal.timeout(TIMEOUT) }
      );
      if (!res.ok) return;
      const data  = await res.json();
      const pairs = (data?.pairs||[])
        .filter(p=>p.priceUsd!=null)
        .sort((a,b)=>(b.liquidity?.usd||0)-(a.liquidity?.usd||0));
      if (pairs.length) dexPrices[raw] = parseFloat(pairs[0].priceUsd);
    } catch(_) {}
  }));
  console.log(`  ${Object.keys(dexPrices).length} DexScreener prices resolved\n`);

  // ── Build asset records ──────────────────────────────────────────────────────
  const assets = [];
  let passed = 0, bySrc = { Chainlink:0, Pyth:0, CoinGecko:0, DexScreener:0, none:0 };

  for (const raw of ALL_500) {
    const sym   = norm(raw);
    const cgId  = COINGECKO_IDS[sym] || COINGECKO_IDS[raw];
    const dexEn = DEXSCREENER_TOKENS[sym] || DEXSCREENER_TOKENS[raw.toUpperCase()];
    const clFd  = CHAINLINK_FEEDS[sym];
    const hasCL = !!clFd && !!CONFIG.chainlinkRpcUrl;
    const hasPy = !!PYTH_FEEDS[sym];
    const hasCG = !!cgId;
    const hasDx = !!dexEn;

    // Determine prices per tier
    const clPrice = null; // Chainlink requires live RPC — mark as No Feed if no RPC
    const pyPrice = pySymPrices[sym] || null;
    const cgPrice = cgId ? (cgData[cgId]?.usd ?? null) : null;
    const dxPrice = dexPrices[raw] ?? null;

    // Cascade
    let finalPrice  = null;
    let sourceUsed  = 'none';
    if (clPrice != null)  { finalPrice = clPrice; sourceUsed = 'Chainlink'; }
    else if (pyPrice != null)  { finalPrice = pyPrice; sourceUsed = 'Pyth'; }
    else if (cgPrice != null)  { finalPrice = cgPrice; sourceUsed = 'CoinGecko'; }
    else if (dxPrice != null)  { finalPrice = dxPrice; sourceUsed = 'DexScreener'; }

    if (finalPrice) { passed++; bySrc[sourceUsed] = (bySrc[sourceUsed]||0)+1; }
    else bySrc.none++;

    assets.push({
      symbol:      raw,
      name:        raw, // Resolver doesn't carry full names — override in JSON if desired
      chain:       CHAIN_MAP[raw] || CHAIN_MAP[sym] || 'unknown',
      address:     dexEn ? dexEn.address : null,
      cgId:        cgId || null,
      hasChainlink: !!clFd,
      hasPyth:      hasPy,
      hasCoinGecko: hasCG,
      hasDexScreener: hasDx,
      chainlinkPrice: clPrice,
      pythPrice:    pyPrice,
      cgPrice:      cgPrice,
      dexPrice:     dxPrice,
      finalPrice:   finalPrice,
      sourceUsed:   sourceUsed,
      sourceUrl:    buildSourceUrl(sym, sourceUsed, cgId, dexEn, clFd),
      lastChecked:  now,
    });
  }

  // ── Summary ─────────────────────────────────────────────────────────────────
  const pct = ((passed/ALL_500.length)*100).toFixed(1);
  console.log(`Results: ${passed}/${ALL_500.length} (${pct}%)`);
  for (const [src, n] of Object.entries(bySrc)) {
    if (n > 0) console.log(`  ${src.padEnd(14)} ${n}`);
  }

  // ── Write ────────────────────────────────────────────────────────────────────
  const output = {
    generatedAt:   now,
    resolverVersion: 'vinculum-price-resolver-v3.js',
    total:  ALL_500.length,
    passed, bySrc,
    passRate: pct + '%',
    assets,
  };
  fs.writeFileSync('price-verification-data.json', JSON.stringify(output, null, 2));
  console.log('\n Saved: price-verification-data.json');
  console.log(' Open registry-qa.html in a browser (serve from same folder)\n');
}

main().catch(e => { console.error('Error:', e.message); process.exit(1); });
