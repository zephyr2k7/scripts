#!/bin/bash

# Script is brought to you by ATADA_Stakepool, Telegram @atada_stakepool in
# cooperation with @TheRealAdamDean (BUFFY & SPIKE)

#load variables from common.sh
#       socket          Path to the node.socket (also exports socket to CARDANO_NODE_SOCKET_PATH)
#       genesisfile     Path to the genesis.json
#       magicparam      TestnetMagic parameter
#       cardanocli      Path to the cardano-cli executable
. "$(dirname "$0")"/00_common.sh

case $# in
  2 ) fromAddr="$1";
      metafile="$2.json";;
  * ) cat >&2 <<EOF
Usage:  $(basename $0) <From AddressName> <VoteFileName>.json
EOF
  exit 1;; esac

#This is a simplified Version of the sendLovelaces.sh script so, it will always be a SendALLLovelaces transaction + Metafile
toAddr=${fromAddr}
lovelacesToSend="ALL"

#Throw an error if the voting.json file does not exist
if [ ! -f "${metafile}" ]; then
  echo -e "The specified VoteFileName.json (${metafile} file does not exist. Please try again."
  exit 1
fi

function readMetaParam() {
  required="${3:-0}"
  key=$(jq 'keys[0]' $2)
  param=$(jq -r ".$key .$1" $2 2> /dev/null)
  if [[ $? -ne 0 ]]; then echo "ERROR - ${2} is not a valid JSON file" >&2; exit 1;
  elif [[ "${param}" == null && required -eq 1 ]]; then echo "ERROR - Parameter \"$1\" in ${2} does not exist" >&2; exit 1;
  elif [[ "${param}" == "" && !required -eq 1 ]]; then echo "ERROR - Parameter \"$1\" in ${2} is empty" >&2; exit 1;
  fi
  echo "${param}"
}

objectType=$(readMetaParam "ObjectType" "${metafile}" 1); if [[ ! $? == 0 ]]; then exit 1; fi
objectVersion=$(readMetaParam "ObjectVersion" "${metafile}"); if [[ ! $? == 0 ]]; then exit 1; fi

if [[ $objectType == 'VoteBallot' ]]; then
  # Check VoteBallot required fields
  networkId=$(readMetaParam "NetworkId" "${metafile}" 1); if [[ ! $? == 0 ]]; then exit 1; fi
  proposalId=$(readMetaParam "ProposalId" "${metafile}" 1); if [[ ! $? == 0 ]]; then exit 1; fi
  voterId=$(readMetaParam "VoterId" "${metafile}" 1); if [[ ! $? == 0 ]]; then exit 1; fi
  yesnovote=$(readMetaParam "Vote" "${metafile}"); if [[ ! $? == 0 ]]; then exit 1; fi
  choicevote=$(readMetaParam "Choices" "${metafile}"); if [[ ! $? == 0 ]]; then exit 1; fi
  if [[ $yesnovote == null && $choicevote == null ]]; then
    echo "ERROR - No voting preferences found in ballot.";
    exit 1;
  fi
else
    echo "ERROR - JSON is not of type VoteBallot.";
    exit 1;
fi

sendFromAddr=$(cat ${fromAddr}.addr)
sendToAddr=$(cat ${toAddr}.addr)
check_address "${sendFromAddr}"
check_address "${sendToAddr}"

#Choose between sending ALL funds or a given amount of lovelaces out
if [[ ${lovelacesToSend^^} == "ALL" ]]; then
  #Sending ALL lovelaces, so only 1 receiver address
  rxcnt="1"
else
  #Sending a free amount, so 2 receiver addresses
  rxcnt="2"  #transmit to two addresses. 1. destination address, 2. change back to the source address
fi

echo
echo -e "\e[0mUsing lovelaces from Address\e[32m ${fromAddr}.addr\e[0m to send the metafile\e[32m ${metafile}\e[0m:"
echo

#get live values
currentTip=$(get_currentTip)
ttl=$(get_currentTTL)
currentEPOCH=$(get_currentEpoch)

echo -e "\e[0mCurrent Slot-Height:\e[32m ${currentTip} \e[0m(setting TTL[invalid_hereafter] to ${ttl})"
echo
echo -e "\e[0mSource/Destination Address ${fromAddr}.addr:\e[32m ${sendFromAddr} \e[90m"
echo -e "\e[0mAttached Metafile:\e[32m ${metafile} \e[90m"
echo

#Get UTX0 Data for the address
utxoJSON=$(${cardanocli} ${subCommand} query utxo --address ${sendFromAddr} --cardano-mode ${magicparam} ${nodeEraParam} --out-file /dev/stdout); checkError "$?";
txcnt=$(jq length <<< ${utxoJSON}) #Get number of UTXO entries (Hash#Idx)
if [[ ${txcnt} == 0 ]]; then echo -e "\e[35mNo funds on the Source Address!\e[0m\n"; exit; else echo -e "\e[32m${txcnt} UTXOs\e[0m found on the Source Address!\n"; fi

#Calculating the total amount of lovelaces in all utxos on this address
totalLovelaces=$(jq '[.[].amount] | add' <<< ${utxoJSON})

#List all found UTXOs and generate the txInString for the transaction
txInString=""
for (( tmpCnt=0; tmpCnt<${txcnt}; tmpCnt++ ))
do
  utxoHashIndex=$(jq -r "keys[${tmpCnt}]" <<< ${utxoJSON})
  txInString="${txInString} --tx-in ${utxoHashIndex}"
  utxoAmount=$(jq -r ".\"${utxoHashIndex}\".amount" <<< ${utxoJSON})
  echo -e "Hash#Idx: ${utxoHashIndex}\tAmount: ${utxoAmount}"
done
echo -e "\e[0m-----------------------------------------------------------------------------------------------------"
totalInADA=$(bc <<< "scale=6; ${totalLovelaces} / 1000000")
echo -e "Total balance on the Address:\e[32m  ${totalInADA} ADA / ${totalLovelaces} lovelaces \e[0m"
echo

#Getting protocol parameters from the blockchain, calculating fees
${cardanocli} ${subCommand} query protocol-parameters --cardano-mode ${magicparam} ${nodeEraParam} > protocol-parameters.json

#Get the current minUTxOvalue
minUTXO=$(jq -r .minUTxOValue protocol-parameters.json 2> /dev/null)

#Generate Dummy-TxBody file for fee calculation
	txBodyFile="${tempDir}/dummy.txbody"
	rm ${txBodyFile} 2> /dev/null
	if [[ ${rxcnt} == 1 ]]; then  #Sending ALL funds  (rxcnt=1)
                        ${cardanocli} ${subCommand} transaction build-raw ${nodeEraParam} ${txInString} --tx-out ${dummyShelleyAddr}+0 --invalid-hereafter ${ttl} --fee 0 --metadata-json-file ${metafile} --out-file ${txBodyFile}
			checkError "$?"
                        else  #Sending chosen amount (rxcnt=2)
                        ${cardanocli} ${subCommand} transaction build-raw ${nodeEraParam} ${txInString} --tx-out ${dummyShelleyAddr}+0 --tx-out ${dummyShelleyAddr}+0 --metadata-json-file ${metafile} --invalid-hereafter ${ttl} --fee 0 --out-file ${txBodyFile}
			checkError "$?"
	fi
fee=$(${cardanocli} ${subCommand} transaction calculate-min-fee --tx-body-file ${txBodyFile} --protocol-params-file protocol-parameters.json --tx-in-count ${txcnt} --tx-out-count ${rxcnt} ${magicparam} --witness-count 1 --byron-witness-count 0 | awk '{ print $1 }')
checkError "$?"
echo -e "\e[0mMinimum Transaction Fee for ${txcnt}x TxIn & ${rxcnt}x TxOut: \e[32m ${fee} lovelaces \e[90m"

#If sending ALL funds
if [[ ${rxcnt} == 1 ]]; then lovelacesToSend=$(( ${totalLovelaces} - ${fee} )); fi

#calculate new balance for destination address
lovelacesToReturn=$(( ${totalLovelaces} - ${fee} - ${lovelacesToSend} ))

#Checking about minimum funds in the UTXO
if [[ ${lovelacesToReturn} -lt 0 || ${lovelacesToSend} -lt 0 ]]; then echo -e "\e[35mNot enough funds on the source Addr!\e[0m"; exit; fi

#Checking about the minimum UTXO that can be transfered according to the current set parameters
lovelacesMinCheck=$(( ${totalLovelaces} - ${fee} )) #hold the value of the lovelaces that will be transfered out no mather what type of transaction
if [[ ${lovelacesMinCheck} -lt ${minUTXO} ]]; then echo -e "\e[35mAt least ${minUTXO} lovelaces must be transfered (ParameterSetting)!\e[0m"; exit; fi

echo -e "\e[0mLovelaces to return to ${toAddr}.addr: \e[33m ${lovelacesToSend} lovelaces \e[90m"

echo

txBodyFile="${tempDir}/$(basename ${fromAddr}).txbody"
txFile="${tempDir}/$(basename ${fromAddr}).tx"

echo
echo -e "\e[0mBuilding the unsigned transaction body: \e[32m ${txBodyFile} \e[90m"
echo

#Building unsigned transaction body
rm ${txBodyFile} 2> /dev/null
if [[ ${rxcnt} == 1 ]]; then  #Sending ALL funds  (rxcnt=1)
			${cardanocli} ${subCommand} transaction build-raw ${nodeEraParam} ${txInString} --tx-out ${sendToAddr}+${lovelacesToSend} --invalid-hereafter ${ttl} --fee ${fee} --metadata-json-file ${metafile} --out-file ${txBodyFile}
			checkError "$?"
			else  #Sending chosen amount (rxcnt=2)
			${cardanocli} ${subCommand} transaction build-raw ${nodeEraParam} ${txInString} --tx-out ${sendToAddr}+${lovelacesToSend} --tx-out ${sendFromAddr}+${lovelacesToReturn} --metadata-json-file ${metafile} --invalid-hereafter ${ttl} --fee ${fee} --out-file ${txBodyFile}
			checkError "$?"
fi

#for more input(utxos) or outputaddresse just add more like
#cardano-cli shelley transaction build-raw \
#     --tx-in txHash#index \
#     --tx-out addr1+10 \
#     --tx-out addr2+20 \
#     --tx-out addr3+30 \
#     --tx-out addr4+40 \
#     --invalid-hereafter 100000 \
#     --fee some_fee_here \
#     --tx-body-file tx.raw
#     (--certificate cert.file)

cat ${txBodyFile}
echo

echo -e "\e[0mSign the unsigned transaction body with the \e[32m${fromAddr}.skey\e[0m: \e[32m ${txFile} \e[90m"
echo

#Sign the unsigned transaction body with the SecureKey
rm ${txFile} 2> /dev/null
${cardanocli} ${subCommand} transaction sign --tx-body-file ${txBodyFile} --signing-key-file ${fromAddr}.skey ${magicparam} --out-file ${txFile} 
checkError "$?"

cat ${txFile}
echo

if ask "\e[33mDoes this look good for you, continue ?" N; then
	echo
	echo -ne "\e[0mSubmitting the transaction via the node..."
	${cardanocli} ${subCommand} transaction submit --tx-file ${txFile} --cardano-mode ${magicparam}
	checkError "$?"
	echo -e "\e[32mDONE\n"
fi


echo -e "\e[0m\n"
