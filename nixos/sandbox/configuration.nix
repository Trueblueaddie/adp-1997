{ modulesPath, config, pkgs, lib, inputs, system, ... }:

let
  cardanoNodePackages = inputs.cardano-node.packages."${pkgs.system}";
  plutusProgs = inputs.self.packages."${pkgs.system}".always-succeed;
in
{
  imports = [
    ../cardano-node-cluster/cardano-node-cluster.nix
  ];

  environment.systemPackages = [
    # Make cardano-testnet and required packages available on machine
    cardanoNodePackages.cardano-cli
    cardanoNodePackages.cardano-node
    cardanoNodePackages.cardano-node-chairman
    cardanoNodePackages.cardano-testnet
    # "/nix/store/19022nw7i67k3r1yakxpll0abf9a8fn8-source"
    pkgs.git
    pkgs.vim
    pkgs.tree
    pkgs.jq
    (pkgs.writeShellScriptBin "start-cluster" (builtins.readFile ../../script.sh))
    plutusProgs
    (pkgs.writeShellScriptBin "run-plutus-always-succeeds" ''
    set -euo pipefail

    # Link our key with all the funds
    ln -sf /var/lib/cardano-node/state/addresses/user1.skey ./payment1.skey
    ln -sf /var/lib/cardano-node/state/addresses/user1.vkey ./payment1.vkey
    ln -sf /var/lib/cardano-node/state/addresses/user1.addr ./payment1.addr

    # Create a new set of keys to hold collateral
    cardano-cli address key-gen \
      --verification-key-file payment2.vkey \
      --signing-key-file payment2.skey

    cardano-cli stake-address key-gen \
      --verification-key-file stake2.vkey \
      --signing-key-file stake2.skey

    cardano-cli address build \
      --payment-verification-key-file payment2.vkey \
      --stake-verification-key-file stake2.vkey \
      --out-file payment2.addr \
      --testnet-magic 42

    # Send some funds to our collateral address
    TX_IN=$(cardano-cli query utxo --address $(cat payment1.addr) --testnet-magic 42 | tail -n1 | awk '{ print $1 }')#0
    cardano-cli transaction build \
      --alonzo-era \
      --testnet-magic 42 \
      --change-address $(cat payment1.addr) \
      --tx-in $TX_IN \
      --tx-out $(cat payment2.addr)+500000000 \
      --out-file tx.build

    cardano-cli transaction sign \
      --tx-body-file tx.build \
      --testnet-magic 42 \
      --signing-key-file payment1.skey \
      --out-file tx.signed

    cardano-cli transaction submit --tx-file tx.signed --testnet-magic 42
    sleep 5

    # payment2.addr should now have some funds
    echo "Transferred funds from $(cat payment1.addr) to $(cat payment2.addr) to use as collateral: "
    echo ""
    echo "$(cat payment1.addr): "
    cardano-cli query utxo --address $(cat payment1.addr) --testnet-magic 42
    echo ""
    echo "$(cat payment2.addr): "
    cardano-cli query utxo --address $(cat payment2.addr) --testnet-magic 42
    echo ""

    echo "Compiling Plutus script..."
    echo ""
    always-succeed 42 alwayssucceeds.plutus

    echo "Building script address..."
    echo ""
    cardano-cli address build \
      --payment-script-file alwayssucceeds.plutus \
      --testnet-magic 42 \
      --out-file script.addr

    echo "Script address is: $(cat script.addr)"

    echo "Getting hash of datum value 42 ..."
    echo ""
    SCRIPT_DATUM_HASH=$(cardano-cli transaction hash-script-data --script-data-value 42)
    echo "Datum hash is ''${SCRIPT_DATUM_HASH}"

    cardano-cli query protocol-parameters \
      --testnet-magic 42 \
      --out-file pparams.json

    TX_IN=$(cardano-cli query utxo --address $(cat payment1.addr) --testnet-magic 42 | tail -n1 | awk '{ print $1 }')#0
    echo "Sending funds from ''${TX_IN} to be locked at the script address ..."
    echo ""
    cardano-cli transaction build \
      --alonzo-era \
      --testnet-magic 42 \
      --change-address $(cat payment1.addr) \
      --tx-in $TX_IN \
      --tx-out $(cat script.addr)+1379280 \
      --tx-out-datum-hash "''${SCRIPT_DATUM_HASH}" \
      --protocol-params-file pparams.json \
      --out-file tx-script.build

    cardano-cli transaction sign \
      --tx-body-file tx-script.build \
      --signing-key-file payment1.skey \
      --testnet-magic 42 \
      --out-file tx-script.signed

    cardano-cli transaction submit --testnet-magic 42 --tx-file tx-script.signed

    sleep 5
    echo "Funds should now be present at the script addr:"
    echo ""
    cardano-cli query utxo --address $(cat script.addr) --testnet-magic 42

    COLLATERAL_TX_IN=$(cardano-cli query utxo --address $(cat payment2.addr) --testnet-magic 42 | tail -n1 | awk '{ print $1 }')
    COLLATERAL_TX_IX=$(cardano-cli query utxo --address $(cat payment2.addr) --testnet-magic 42 | tail -n1 | awk '{ print $2 }')
    COLLATERAL_UTXO="''${COLLATERAL_TX_IN}#''${COLLATERAL_TX_IX}"

    SCRIPT_TX_IN=$(cardano-cli query utxo --address $(cat script.addr) --testnet-magic 42 | tail -n1 | awk '{ print $1 }')
    SCRIPT_TX_IX=$(cardano-cli query utxo --address $(cat script.addr) --testnet-magic 42 | tail -n1 | awk '{ print $2 }')
    SCRIPT_UTXO="''${SCRIPT_TX_IN}#''${SCRIPT_TX_IX}"

    echo "Unlocking funds at script address with redeemer 42 (any will do as the Plutus script always succeeds ..."
    echo ""
    cardano-cli transaction build \
      --alonzo-era \
      --testnet-magic 42 \
      --tx-in ''${SCRIPT_UTXO} \
      --tx-in-script-file alwayssucceeds.plutus \
      --tx-in-datum-value 42 \
      --tx-in-redeemer-value 42 \
      --tx-in-collateral ''${COLLATERAL_UTXO} \
      --change-address $(cat payment1.addr) \
      --protocol-params-file pparams.json \
      --witness-override 2 \
      --out-file test-alonzo.tx

      cardano-cli transaction sign \
        --tx-body-file test-alonzo.tx \
        --signing-key-file payment1.skey \
        --signing-key-file payment2.skey \
        --testnet-magic 42 \
        --out-file test-alonzo.signed

      cardano-cli transaction submit --testnet-magic 42 --tx-file test-alonzo.signed

      sleep 5

      echo "The script address should now have no funds:"
      echo ""
      cardano-cli query utxo --address $(cat script.addr) --testnet-magic 42

      echo "The payment address should now have the funds from the script address:"
      echo ""
      cardano-cli query utxo --address $(cat payment1.addr) --testnet-magic 42

      echo "And the collateral funds should not have been used:"
      echo ""
      cardano-cli query utxo --address $(cat payment2.addr) --testnet-magic 42
    '')
  ];

  environment.interactiveShellInit = ''
    export CARDANO_NODE_SRC=${inputs.cardano-node.sourceInfo}
    export CARDANO_NODE_SOCKET_PATH=/var/lib/cardano-node/state/node-bft1/node.sock
  '';

  # For flakes
  nix = {
    # package = pkgs.nix_2_7;
    extraOptions = ''
      builders = @/etc/nix/machines
      builders-use-substitutes = true
      experimental-features = nix-command flakes
    '';
  };

  # For cached builds
  nix.binaryCaches = [
    "https://cache.nixos.org"
    "https://cache.iog.io"
  ];
  nix.binaryCachePublicKeys = [
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
  ];

  # TODO remove
  users.users.root.initialPassword = "";
}
