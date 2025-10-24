#!/usr/bin/env bash
set -euo pipefail

# Load .env if present
if [ -f .env ]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' .env | xargs -0 -I {} bash -lc 'printf %s "{}"' 2>/dev/null || true) || true
fi

if [ -z "${PRIVATE_KEY:-}" ]; then
  echo "PRIVATE_KEY is required (set in env or .env)" >&2
  exit 1
fi

# Configure RPC and token addresses (Polygon Amoy defaults)
POLYGON_AMOY_RPC=${POLYGON_AMOY_RPC:-}
if [ -z "$POLYGON_AMOY_RPC" ]; then
  if [ -n "${ALCHEMY_KEY:-}" ]; then
    POLYGON_AMOY_RPC="https://polygon-amoy.g.alchemy.com/v2/OdGfAJzOcimvQbvwlzgPFKM2tMO-1fvx"
  else
    echo "Set POLYGON_AMOY_RPC or ALCHEMY_KEY in env/.env" >&2
    exit 1
  fi
fi

if [[ ! "$POLYGON_AMOY_RPC" =~ ^https?:// ]]; then
  echo "POLYGON_AMOY_RPC must start with http(s)://" >&2
  exit 1
fi

POLYGON_USDC_ADDRESS=${POLYGON_USDC_ADDRESS:-0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582}

echo "[setup] Using RPC: $POLYGON_AMOY_RPC"

# Determine UNIVERSAL contract address
if [[ -n "${UNIVERSAL:-}" && "$UNIVERSAL" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "[setup] Using provided UNIVERSAL=$UNIVERSAL"
else
  echo "[setup] Deploying universal contract..."
  UNIVERSAL=$(npx tsx commands/index.ts deploy -k "$PRIVATE_KEY" | node -e '
let s="";process.stdin.on("data",d=>s+=d);
process.stdin.on("end",()=>{try{const o=JSON.parse(s);if(o.contractAddress){console.log(o.contractAddress)}else{process.exit(1)}}catch(e){process.exit(1)}});')
  if [[ ! "$UNIVERSAL" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "Failed to obtain UNIVERSAL contract address" >&2
    exit 1
  fi
  echo "[setup] Deployed UNIVERSAL=$UNIVERSAL"
fi

# Fetch ZRC20 for USDC on Amoy
ZRC20_POLYGON_USDC=$(npx -y zetachain q tokens show --symbol USDC.AMOY -f zrc20)
if [[ ! "$ZRC20_POLYGON_USDC" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "Failed to resolve ZRC20 for USDC.AMOY" >&2
  exit 1
fi
echo "[setup] ZRC20_POLYGON_USDC=$ZRC20_POLYGON_USDC"

# Derive recipient from private key
if command -v cast >/dev/null 2>&1; then
  RECIPIENT=$(cast wallet address "$PRIVATE_KEY")
else
  RECIPIENT=$(node -e 'const {Wallet}=require("ethers");console.log(new Wallet(process.env.PRIVATE_KEY).address)')
fi

if [[ ! "$RECIPIENT" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "Failed to derive RECIPIENT address" >&2
  exit 1
fi
echo "[setup] RECIPIENT=$RECIPIENT"

echo "[setup] Sending 1 USDC via deposit-and-call..."
npx zetachain evm deposit-and-call \
  --chain-id 80002 \
  --rpc "$POLYGON_AMOY_RPC" \
  --erc20 "$POLYGON_USDC_ADDRESS" \
  --amount 1 \
  --types address bytes bool \
  --receiver "$UNIVERSAL" \
  --values "$ZRC20_POLYGON_USDC" "$RECIPIENT" true \
  --private-key "$PRIVATE_KEY" \
  --yes

echo "[setup] Done."