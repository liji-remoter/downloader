#!/bin/bash
source ./download.conf

prepare_remote_resources () {
	echo "正在准备远程服务器资源..."
	ssh $REMOTE_SSH_HOST "wget -c -o /dev/null -O /var/www/html/origin_${PACKAGE_NAME} '${ORIGINAL_DOWNLOAD_URL}'"
	CONTENT_LENGTH=`curl -I ${REMOTE_HTTP_HOST}/origin_${PACKAGE_NAME} | grep 'Content-Length' | awk '{print $2}'`
	CONTENT_LENGTH=${CONTENT_LENGTH//[ $'\r']}
	echo $(( CONTENT_LENGTH / 100 ))
	if (( CONTENT_LENGTH > MIN_LARGE_FILE_LENGTH )); then
		SUBCONTENT_LENGTH=256000
	else
		SUBCONTENT_LENGTH=128000
	fi
	echo "文件大小为: $CONTENT_LENGTH"
	echo "文件分片大小为: $SUBCONTENT_LENGTH"
	ssh $REMOTE_SSH_HOST "rm -rf /var/www/html/${PACKAGE_NAME} && mkdir /var/www/html/${PACKAGE_NAME} && cd /var/www/html/${PACKAGE_NAME} && split -b $SUBCONTENT_LENGTH ../origin_${PACKAGE_NAME} && ls x* | xargs md5sum > ${LIST_FILE_NAME}"
}

download_file_list () {
	echo "正在下载${PACKAGE_NAME}分片列表"
	curl -o "${WORKSPACE_FOLDER}/${LIST_FILE_NAME}" "${PACKAGE_LIST_URL}" > /dev/null 2>&1
}

get_last_file_name () {
	IFS=$'\n' command eval 'FILE_LIST=($(cat "${WORKSPACE_FOLDER}/${LIST_FILE_NAME}" | awk "{print \$2}"))'
	LAST_FILE=`echo ${FILE_LIST[${#FILE_LIST[@]}-1]}`
}

download_files () {
	for file_name in `command eval $1`; do
		while true; do
			DOWNLOADING_COUNT=`ps aux|grep $WORKSPACE_FOLDER |grep -v 'grep' |wc -l | sed "s/^[ \t]*//"`
			if [ $DOWNLOADING_COUNT -eq $MAX_DOWNLOAD_THREAD_COUNT ]; then
				sleep 1
			else
				echo "正在下载${file_name}..."
				curl -m 60 -o "${WORKSPACE_FOLDER}/${file_name}" "${PACKAGE_ROOT_URL}/${file_name}" > /dev/null 2>&1 &
				break
			fi
		done
	done
}

trace_download_process () {
	while true; do
		DOWNLOADING_COUNT=`ps aux|grep "${WORKSPACE_FOLDER}" |grep -v 'grep' |wc -l | sed "s/^[ \t]*//"`
		if [ $DOWNLOADING_COUNT -eq 0 ]; then
			break
		fi
		echo "剩余下载任务: $DOWNLOADING_COUNT"
		sleep 5
	done
}

verify_files () {
    local MD5_STRINGS=$(cat ${WORKSPACE_FOLDER}/${LIST_FILE_NAME}|awk "{print \$1}" | xargs)
    local DOWNLOADED_FILES=$(ls ${WORKSPACE_FOLDER}|grep -v ${LIST_FILE_NAME} | xargs)
    for file_name in $DOWNLOADED_FILES; do
        VERIFY_COMMAND=$(md5_verify_command)
        if [[ ! $MD5_STRINGS =~ $(command eval ${VERIFY_COMMAND}) ]]; then
            download_files "echo $file_name"
        fi
    done
    trace_download_process
}

md5_verify_command () {
    case ${SYSTEM_TYPE} in
        Linux)
            echo 'md5sum ${WORKSPACE_FOLDER}/$file_name | awk "{print \$1}"'
            ;;
        Darwin)
            echo 'md5 ${WORKSPACE_FOLDER}/$file_name | awk "{printf \$4}"'
            ;;
    esac
}

try_to_download_files() {
    download_files 'cat "${WORKSPACE_FOLDER}/${LIST_FILE_NAME}" | awk "{print \$2}"'
    trace_download_process
    local FAILED_FILES_CHECK_COMMAND='ls -l ${WORKSPACE_FOLDER} |cat |grep -v "$SUBCONTENT_LENGTH\|grep\|$LIST_FILE_NAME\|total\|$LAST_FILE" |awk "{print \$9}"'
    while [ -n "`command eval ${FAILED_FILES_CHECK_COMMAND}`" ]; do
        download_files "${FAILED_FILES_CHECK_COMMAND}"
        trace_download_process
        verify_files
    done

}

cleanup_temp () {
    cat ${WORKSPACE_FOLDER}/x* > ${DOWNLOAD_PATH}/${PACKAGE_NAME}
	  echo "正在清理临时文件..."
	  ssh $REMOTE_SSH_HOST "rm -rf /var/www/html/origin_${PACKAGE_NAME} /var/www/html/${PACKAGE_NAME}"
	  rm -rf ${WORKSPACE_FOLDER}
}

print_summary () {
	CONTENT_LENGTH=`curl -I ${REMOTE_HTTP_HOST}/origin_${PACKAGE_NAME} | grep 'Content-Length' | awk '{print $2}'`
	CONTENT_LENGTH=${CONTENT_LENGTH//[ $'\r']}
	TAKEN_SECONDS=$((`date +%s` - START_TIMESTAMP))
  SPEED=$(echo "$CONTENT_LENGTH / $TAKEN_SECONDS / 1000" | bc)
	echo "下载用时 $TAKEN_SECONDS 秒"
	echo "平均下载速度为: $SPEED"
	echo "完成"
	echo "${DOWNLOAD_PATH}/${PACKAGE_NAME}"
}

ORIGINAL_DOWNLOAD_URL=$1
IFS=$'/' command eval 'PARSED_URL=(${ORIGINAL_DOWNLOAD_URL})'
PACKAGE_NAME=`echo ${PARSED_URL[${#PARSED_URL[@]}-1]} |sed 's/\?.*//g'`
LIST_FILE_NAME="split_list.txt"
PACKAGE_ROOT_URL="${REMOTE_HTTP_HOST}/${PACKAGE_NAME}"
PACKAGE_LIST_URL="${PACKAGE_ROOT_URL}/${LIST_FILE_NAME}"
WORKSPACE_FOLDER=`mktemp -d`
DOWNLOADING_COUNT_FILE="${WORKSPACE_FOLDER}/downloading_count"
MIN_LARGE_FILE_LENGTH=20480000
START_TIMESTAMP=`date +%s`
SYSTEM_TYPE=$(uname)

echo "开始${PACKAGE_NAME}下载进程..."

prepare_remote_resources
download_file_list
get_last_file_name

try_to_download_files
cleanup_temp
print_summary

