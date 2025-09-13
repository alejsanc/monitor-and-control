#!/usr/bin/bash

. /etc/tapo.conf
. /usr/local/lib/notifications.sh

sha256hash () {
    echo -n $1 | sha256sum | head -c 64 | tr [:lower:] [:upper:]
}

init () {

    client_nonce=$(dd if=/dev/urandom bs=8 count=1 status=none | xxd -p -u)

    request="{\"method\": \"login\", \"params\": {\"cnonce\": \"$client_nonce\", \"username\": \"$USERNAME\"}}"
    response=$(curl -ksd "$request" https://$HUB)

    server_nonce=$(echo $response | jq -r .result.data.nonce)
    device_confirm=$(echo $response | jq -r .result.data.device_confirm)
    expected_device_confirm=$(sha256hash $client_nonce$PASSWORD_HASH$server_nonce)$server_nonce$client_nonce
	
    if [ "$device_confirm" != "$expected_device_confirm" ]
    then
        send_notification "Tapo Hub: Device confirm mismatch"
        exit
    fi

    digest_passwd=$(sha256hash $PASSWORD_HASH$client_nonce$server_nonce)$client_nonce$server_nonce

    request="{\"method\": \"login\", \"params\": {\"cnonce\": \"$client_nonce\", \"digest_passwd\": \"$digest_passwd\", \"username\": \"$USERNAME\"}}"
    response=$(curl -ksd "$request" https://$HUB)

    stok=$(echo $response | jq -r .result.stok)
    seq=$(echo $response | jq -r .result.start_seq)
    key=$(sha256hash "lsk"$client_nonce$server_nonce$(sha256hash $client_nonce$PASSWORD_HASH$server_nonce) | head -c 32)
    iv=$(sha256hash "ivb"$client_nonce$server_nonce$(sha256hash $client_nonce$PASSWORD_HASH$server_nonce) | head -c 32)

    request="{\"method\": \"multipleRequest\", \"params\": {\"requests\": [$REQUESTS]}}"
    encoded_request=$(echo $request | openssl enc -aes-128-cbc -e -a -A -K $key -iv $iv);
    passthrough="{\"method\":\"securePassthrough\",\"params\":{\"request\":\"$encoded_request\"}}"
}

send_request () {
    tag=$(sha256hash $(sha256hash $PASSWORD_HASH$client_nonce)$passthrough$seq)
    response=$(curl -ksd "$passthrough" -H "Seq: $seq" -H "Tapo_tag: $tag" https://$HUB/stok=$stok/ds)
    error_code=$(echo $response | jq -r .error_code)
}

read_result () {
    result=$(echo $response | jq -r .result.response | openssl enc -aes-128-cbc -d -a -A -K $key -iv $iv)
}

if [ "$1" = "monitor" ]
then

    init

    while true
    do

        time=$(date +%s)

        send_request

        if [ $error_code != 0  ]
        then
            init	
            continue
        fi

        read_result
	
        siren_status=$(echo $result | jq -r .result.responses[0].result.status)

        child_devices=$(echo $result | jq .result.responses[1].result.child_device_list[] | jq -r ".nickname, .signal_level, .jamming_signal_level")
	
        if [ "$siren_status" = "on" ]
        then
            echo "Tapo Hub: Siren Status On"
            aplay -q $SOUND
        fi

        while read base64_nickname
        do
            read signal_level
            read jamming_signal_level

            if [ $signal_level -lt $MIN_SIGNAL_LEVEL ] || [ $jamming_signal_level -gt $MAX_JAMMING_SIGNAL_LEVEL ]
            then
                nickname=$(echo $base64_nickname | base64 -d)
                message="Tapo Hub: $nickname - Signal: $signal_level Jamming: $jamming_signal_level"
                if [[ ! ${sent_messages[@]} =~ "$message" ]]
                then
                    sent_messages+=("$message|$time")
                    send_notification "$message"
                fi
            fi

        done <<< $child_devices

        for message in "${sent_messages[@]}"
        do
            message_time=$(echo $message | cut -d "|" -f 2)

            if [ $((message_time + 1800)) -gt $time ]
            then
                new_sent_messages+=("$message")
            fi

        done

        sent_messages=("${new_sent_messages[@]}")
        new_sent_messages=()

        ((seq++))
        sleep 5

    done

else

    if [ "$1" = "siren" ]
    then

        if [ "$2" = "" ]
        then
            REQUESTS="{\"method\": \"getSirenStatus\", \"params\": {\"siren\": {}}}"
        else
            REQUESTS="{\"method\": \"setSirenStatus\", \"params\": {\"siren\": {\"status\": \"$2\"}}}"
        fi
  
    elif [ "$1" = "info" ]
    then
        REQUESTS="{\"method\": \"getDeviceInfo\", \"params\": {\"device_info\": {}}}" 
    elif [ "$1" = "devices" ]
    then
        REQUESTS="{\"method\": \"getChildDeviceList\", \"params\": {\"childControl\": {\"start_index\": 0}}}"
    else
        echo "Usage: tapo.sh monitor | siren [on|off] | info | devices"  
        exit 
    fi
 
    init
    send_request
    
    if [ $error_code = 0 ]
    then
        read_result

        if [ "$1" = "siren" ] && [ "$2" = "" ]
        then
            echo $result | jq .result.responses[0].result
        elif [ "$1" = "info" ]
        then
            echo $result | jq .result.responses[0].result.device_info.basic_info
        elif [ "$1" = "devices" ]
        then
            echo $result | jq .result.responses[0].result.child_device_list[]
        else 
            echo $result
        fi
    else
        echo $response
    fi
fi
