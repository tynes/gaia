#!/bin/bash

GAIA_BRANCH=mark-do-thing
GAIA_DIR=$(mktemp -d)
CONF_DIR=$(mktemp -d)

echo "GAIA_DIR: ${GAIA_DIR}"
echo "CONF_DIR: ${CONF_DIR}"

sleep 1

set -x

echo "Killing existing gaiad instances..."

killall gaiad

set -e

echo "Building Gaia..."

cd $GAIA_DIR
git clone git@github.com:tynes/gaia
cd gaia
git checkout $GAIA_BRANCH
make install
gaiad version
gaiacli version

echo "Generating configurations..."

cd $CONF_DIR && mkdir ibc-testnets && cd ibc-testnets
echo -e "\n" | gaiad testnet -o ibc0 --v 1 --chain-id ibc0 --node-dir-prefix n
echo -e "\n" | gaiad testnet -o ibc1 --v 1 --chain-id ibc1 --node-dir-prefix n

if [ "$(uname)" = "Linux" ]; then
  sed -i 's/"leveldb"/"goleveldb"/g' ibc0/n0/gaiad/config/config.toml
  sed -i 's/"leveldb"/"goleveldb"/g' ibc1/n0/gaiad/config/config.toml
  sed -i 's#"tcp://0.0.0.0:26656"#"tcp://0.0.0.0:26556"#g' ibc1/n0/gaiad/config/config.toml
  sed -i 's#"tcp://0.0.0.0:26657"#"tcp://0.0.0.0:26557"#g' ibc1/n0/gaiad/config/config.toml
  sed -i 's#"localhost:6060"#"localhost:6061"#g' ibc1/n0/gaiad/config/config.toml
  sed -i 's#"tcp://127.0.0.1:26658"#"tcp://127.0.0.1:26558"#g' ibc1/n0/gaiad/config/config.toml
else
  sed -i '' 's/"leveldb"/"goleveldb"/g' ibc0/n0/gaiad/config/config.toml
  sed -i '' 's/"leveldb"/"goleveldb"/g' ibc1/n0/gaiad/config/config.toml
  sed -i '' 's#"tcp://0.0.0.0:26656"#"tcp://0.0.0.0:26556"#g' ibc1/n0/gaiad/config/config.toml
  sed -i '' 's#"tcp://0.0.0.0:26657"#"tcp://0.0.0.0:26557"#g' ibc1/n0/gaiad/config/config.toml
  sed -i '' 's#"localhost:6060"#"localhost:6061"#g' ibc1/n0/gaiad/config/config.toml
  sed -i '' 's#"tcp://127.0.0.1:26658"#"tcp://127.0.0.1:26558"#g' ibc1/n0/gaiad/config/config.toml
fi;

gaiacli config --home ibc0/n0/gaiacli/ chain-id ibc0
gaiacli config --home ibc1/n0/gaiacli/ chain-id ibc1
gaiacli config --home ibc0/n0/gaiacli/ output json
gaiacli config --home ibc1/n0/gaiacli/ output json
gaiacli config --home ibc0/n0/gaiacli/ node http://localhost:26657
gaiacli config --home ibc1/n0/gaiacli/ node http://localhost:26557

echo "Importing keys..."

SEED0=$(jq -r '.secret' ibc0/n0/gaiacli/key_seed.json)
SEED1=$(jq -r '.secret' ibc1/n0/gaiacli/key_seed.json)
echo -e "12345678\n" | gaiacli --home ibc1/n0/gaiacli keys delete n0

echo "Seed 0: ${SEED0}"
echo "Seed 1: ${SEED1}"

gaiacli keys test --home ibc0/n0/gaiacli n1 "$(jq -r '.secret' ibc1/n0/gaiacli/key_seed.json)" 12345678
gaiacli keys test --home ibc1/n0/gaiacli n0 "$(jq -r '.secret' ibc0/n0/gaiacli/key_seed.json)" 12345678
gaiacli keys test --home ibc1/n0/gaiacli n1 "$(jq -r '.secret' ibc1/n0/gaiacli/key_seed.json)" 12345678

echo "\n\nKeys should match:\n\n"

SENDER=$(gaiacli --home ibc0/n0/gaiacli keys list | jq '.[0].address')
echo $(gaiacli --home ibc0/n0/gaiacli keys list | jq '.[0].address')
echo $SENDER

RECIPIENT=$(gaiacli --home ibc0/n0/gaiacli keys list | jq '.[1].address')
echo $RECIPIENT

gaiacli --home ibc0/n0/gaiacli keys list | jq '.[].address'
gaiacli --home ibc1/n0/gaiacli keys list | jq '.[].address'

echo "Starting Gaiad instances..."

nohup gaiad --home ibc0/n0/gaiad --log_level="*:debug" start > ibc0.log &
nohup gaiad --home ibc1/n0/gaiad --log_level="*:debug" start > ibc1.log &

sleep 20

echo "Creating clients..."

echo -e "12345678\n" | gaiacli --home ibc0/n0/gaiacli \
  tx ibc client create ibconeclient \
  $(gaiacli --home ibc1/n0/gaiacli q ibc client node-state) \
  --from n0 -y -o text

echo -e "12345678\n" | gaiacli --home ibc1/n0/gaiacli \
  tx ibc client create ibczeroclient \
  $(gaiacli --home ibc0/n0/gaiacli q ibc client node-state) \
  --from n1 -y -o text

sleep 3

echo "Querying clients..."

gaiacli --home ibc0/n0/gaiacli q ibc client consensus-state ibconeclient --indent
gaiacli --home ibc1/n0/gaiacli q ibc client consensus-state ibczeroclient --indent

echo "Establishing a connection..."

gaiacli \
  --home ibc0/n0/gaiacli \
  tx ibc connection handshake \
  connectionzero ibconeclient $(gaiacli --home ibc1/n0/gaiacli q ibc client path) \
  connectionone ibczeroclient $(gaiacli --home ibc0/n0/gaiacli q ibc client path) \
  --chain-id2 ibc1 \
  --from1 n0 --from2 n1 \
  --node1 tcp://localhost:26657 \
  --node2 tcp://localhost:26557

sleep 2

echo "Querying connection..."

gaiacli --home ibc0/n0/gaiacli q ibc connection end connectionzero --indent --trust-node
gaiacli --home ibc1/n0/gaiacli q ibc connection end connectionone --indent --trust-node

echo "Establishing a channel..."

gaiacli \
  --home ibc0/n0/gaiacli \
  tx ibc channel handshake \
  ibconeclient bank channelzero connectionzero \
  ibczeroclient bank channelone connectionone \
  --node1 tcp://localhost:26657 \
  --node2 tcp://localhost:26557 \
  --chain-id2 ibc1 \
  --from1 n0 --from2 n1

sleep 2

echo "Querying channel..."

gaiacli --home ibc0/n0/gaiacli q ibc channel end bank channelzero --indent --trust-node
gaiacli --home ibc1/n0/gaiacli q ibc channel end bank channelone --indent --trust-node

echo "Sending token packets from ibc0..."

DEST=$(gaiacli --home ibc0/n0/gaiacli keys show n1 -a)

gaiacli \
  --home ibc0/n0/gaiacli \
  tx ibc transfer transfer \
  bank channelzero \
  $DEST 1stake \
  --from n0 \
  --source

echo "Enter height:"

read -r HEIGHT

TIMEOUT=$(echo "$HEIGHT + 1000" | bc -l)

echo "Account before:"
gaiacli --home ibc1/n0/gaiacli q account $DEST | jq .value.coins

echo "Recieving token packets on ibc1..."

sleep 3

gaiacli \
  tx ibc transfer recv-packet \
  bank channelzero ibczeroclient \
  --home ibc1/n0/gaiacli \
  --packet-sequence 1 \
  --timeout $TIMEOUT \
  --from n1 \
  --node2 tcp://localhost:26657 \
  --chain-id2 ibc0 \
  --source

echo "Account after:"
gaiacli --home ibc1/n0/gaiacli q account $DEST | jq .value.coins

echo ""
echo ""

sleep 5

echo "Submitting Burn Proof"

PROOF=' {"version":"0x02000000","vin":"01f1f1f1765c2da15edd834dc8a8f05d5bdea937af98f8f9994d9afe425baeaab60b00000017160014f82b0900a958d319c81622fdcb674f3b635a0261fdffffff","vout":"0121030000000000001976a914759d6677091e973b9e9d99f19c68fbf43e3f05f988ac","locktime":"0xad2f0900","tx_id":"c419a98ac429e747a4ea5a993d8b5dde6a993dc608094d4c60a5d08fc54b25b5","tx_id_le":"b5254bc58fd0a5604c4d0908c63d996ade5d8b3d995aeaa447e729c48aa919c4","index":1531,"confirming_header":{"raw":"00000020bbe25e837ff2dbb7048688e5470c20b4dc88b3796afb11000000000000000000f6eb5a74be96c8c759b74c14e4781d6069383de7748f48aa2293ffa61dc3ef78b22dbe5ddf8e1417f9765c1c","hash_le":"5ad173b0c1d239471539b8f490e1ea330967eb758e5111000000000000000000","hash":"00000000000000000011518e75eb670933eae190f4b839154739d2c1b073d15a","height":602115,"prevhash":"00000000000000000011fb6a79b388dcb4200c47e5888604b7dbf27f835ee2bb","merkle_root_le":"f6eb5a74be96c8c759b74c14e4781d6069383de7748f48aa2293ffa61dc3ef78","merkle_root":"78efc31da6ff9322aa488f74e73d3869601d78e4144cb759c7c896be745aebf6"},"intermediate_nodes":"b3026e5397de8e15a9fd009b407b5e4c30989dfd0ef788c2e1dfd65786cf0a9ad69e796c77fc5c5715c5d57b5307b5623d99898405456af6f86588be6fcf9a61d4423dc9d541b00161e9573cdd5a683456f56a01a47c3cc3d5f07f3d2ae92c195bd4b26f3265c17a813217a55a02bb01fcef189d1d399ab19aa911824a1ed9aa3c34127e90aafbaebc4ce00a504a4514e2a749c6027bbbd2327933c5addcbd5430dbc5733c10d60b3ac6ec8d510b5bb1f6c4538846131f53334e0f5d57da26e9ae86184271d70de59b9e1f66eb6b213e8fa560b74435f0d3043fc81eb219ab84458c5c9c222cc13de0579b6f56e62774d68cab9b7910832f376caa4dc9aaaf86d63003e031b02afb660e423c78f13bd4d01d154c6326554ae14770856f49946460e6c8debfe74dd80332b644a1a32980993186b6e9c77038d6b87a0e6e6bed4bdb136d749ac34e6af586a50e1c82ef7494524275e239bcde3107a9d33a726be1"}'

BURNPROOF='{"proof": '
BURNPROOF+="$PROOF"
BURNPROOF+=', "headers": [], "signer": '
BURNPROOF+="$SENDER"
BURNPROOF+=', "recipient": '
BURNPROOF+=$RECIPIENT
BURNPROOF+='}'

echo "\n\n\n"
echo $BURNPROOF
echo "\n\n\n"

gaiacli \
    tx burn burnproof "$BURNPROOF" \
    --home ibc0/n0/gaiacli \
    --from n0 \
    --node tcp://localhost:26657

echo "Trying to receive again"

sleep 5

gaiacli \
  tx ibc transfer recv-packet \
  bank channelzero ibczeroclient \
  --home ibc1/n0/gaiacli \
  --packet-sequence 2 \
  --timeout $TIMEOUT \
  --from n1 \
  --node2 tcp://localhost:26657 \
  --chain-id2 ibc0 \
  --source

echo ""

echo "GAIA_DIR: ${GAIA_DIR}"
echo "CONF_DIR: ${CONF_DIR}"
