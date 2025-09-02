#!/usr/bin/env bash

echo "Downloading latest snapshot from Bitnodes..."
mapfile -t bitnodes_peers < <(wget --timeout=300 -qO- https://bitnodes.io/api/v1/snapshots/latest/ | jq -r '.nodes | keys[]')
echo "[*] Total nodes in Bitnodes: ${#bitnodes_peers[@]}"
bitnodes_index=0

while IFS= read -r addr; do
    addrman_peers+=("$addr")
done < <(bitcoin-cli -rpcwait getnodeaddresses 999999 | jq -r '
    .[] |
    if .network == "ipv6" then
        "[\(.address)]:\(.port)"
    else
        "\(.address):\(.port)"
    end
')
echo "[*] Total nodes in addrman: ${#addrman_peers[@]}"
addrman_index=0

total_peers=$(( ${#addrman_peers[@]} + ${#bitnodes_peers[@]} ))

elapsed_peers=0
low_fee_file="peers-low-fee.txt"
touch "$low_fee_file"

while true; do
    if (( elapsed_peers % 5 == 0 )); then
        total_before=$(wc -l < "$low_fee_file")
        mapfile -t new_low_fee_peers < <(bitcoin-cli -rpcwait getpeerinfo | jq -r '
            .[] | select(
                .inbound == false and
                .synced_headers != -1 and
                .relaytxes == true and
                .minfeefilter < 0.000006
            ) | .addr
        ')

        if (( ${#new_low_fee_peers[@]} > 0 )); then
            cat "$low_fee_file" <(printf "%s\n" "${new_low_fee_peers[@]}") | sort -u > "$low_fee_file.tmp"
            mv "$low_fee_file.tmp" "$low_fee_file"
        fi

        total_after=$(wc -l < "$low_fee_file")
        added_count=$((total_after - total_before))

        if (( added_count > 0 )); then
            echo "[+] $added_count new peers added — Total: $total_after"
        else
            echo "[=] No peer new - Total: $total_after"
        fi

        mapfile -t peers_fee_def < <(bitcoin-cli -rpcwait getpeerinfo | jq -r '
            .[] | select(
                .connection_type == "manual" and
                .synced_headers != -1 and
                .minfeefilter >= 0.000008
            ) | .id
        ')
        for id in "${peers_fee_def[@]}"; do
            bitcoin-cli -rpcwait disconnectnode "" $id >/dev/null 2>&1
        done
    fi

    if (( addrman_index < ${#addrman_peers[@]} )); then
        ((addrman_index++))
        total_index=$(( $addrman_index + $bitnodes_index ))
        peer="${addrman_peers[addrman_index]}"
        echo "[${total_index}/${total_peers}] Connecting to $peer"
        bitcoin-cli -rpcwait addnode "$peer" onetry true
    fi
    if (( bitnodes_index < ${#bitnodes_peers[@]} )); then
        ((bitnodes_index++))
        total_index=$(( $addrman_index + $bitnodes_index ))
        peer="${bitnodes_peers[bitnodes_index]}"
        echo "[${total_index}/${total_peers}] Connecting to $peer"
        bitcoin-cli -rpcwait addnode "$peer" onetry true
    fi

    ((elapsed_peers++))
done
