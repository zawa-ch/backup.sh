#! /bin/bash

dbg_echo()
{
	[ -e ".debug" ] && echo "$*"
}

get_uuid()
{
	cat /proc/sys/kernel/random/uuid
}


#	---- 設定項目 ----
#	ここで環境変数に何も指定されていなかった場合のデフォルトの挙動を定義する
#	基本的にはここを変更するの**ではなく**、環境変数を設定してこのスクリプトを実行することを推奨する

#	スナップショットのソースディレクトリ
#	このディレクトリの中に存在するすべての項目に対してスナップショットが作成される
#	必ず絶対パスで指定すること
#	ここで指定したパスが存在しない場合、このスクリプトはスナップショットを作成できない
[ -z "$BACKUP_SOURCE_LOCATION" ] && BACKUP_SOURCE_LOCATION="/source"

#	スナップショットの保管ディレクトリ
#	このディレクトリの中に作成したスナップショットを保管し、管理する
#	必ず絶対パスで指定すること
#	ここで指定したパスが存在しない場合、自動的にディレクトリが作成される
[ -z "$BACKUP_DESTINATION_LOCATION" ] && BACKUP_DESTINATION_LOCATION="/destination"

#	データベースファイルの名前
#	BACKUP_DESTINATION_LOCATION で指定した管理ディレクトリに配置されるデータベースファイルの名前を指定する
[ -z "$BACKUP_DB_FILENAME" ] && BACKUP_DB_FILENAME="database.json"

#	スナップショットの圧縮方式
#	ここで指定した方式でスナップショットが圧縮され、保管される
#	有効な設定は "plain"(無圧縮), "gzip"(GNU gzip), "zstd"(Z Standard)
[ -z "$BACKUP_COMPRESSION_METHOD" ] && BACKUP_COMPRESSION_METHOD="zstd"

#	スナップショット管理ルール
#	作成したスナップショットはここで指定したルールに従って管理される
#	ルールはJSONの特定の構造を持ったオブジェクトの配列で記述する
#	空のJSON配列を渡すことでルールベースの管理を無効化し、全エントリを保管するようになる
[ -z "$BACKUP_KEEP_RULES" ] && BACKUP_KEEP_RULES='[]'

#	---- 設定項目ここまで ----


database_location="$BACKUP_DESTINATION_LOCATION/$BACKUP_DB_FILENAME"

#	初期化処理
#
#	初回実行時などに必要なデータやファイルを構築する
#	データベースが破損している場合はここで初期化される
init()
{
	{ [ -z "$BACKUP_SOURCE_LOCATION" ] || [ -z "$BACKUP_DESTINATION_LOCATION" ] || [ -z "$BACKUP_DB_FILENAME" ] || [ -z "$BACKUP_COMPRESSION_METHOD" ] || [ -z "$BACKUP_KEEP_RULES" ]; } && {
		echo "E: Configuration error" >&2
		return 2
	}
	if ! [ -d "$BACKUP_DESTINATION_LOCATION" ]; then
		mkdir -p "$BACKUP_DESTINATION_LOCATION" || {
			echo "E: Can't create directory $BACKUP_DESTINATION_LOCATION" >&2
			return 2
		}
	fi
	if ! [ -f "$database_location" ]; then
		echo "Initializing..."
		echo "{}" >"$database_location"
	elif ! echo "{}" | jq --argjson data "$(cat "$database_location")" '.' >/dev/null 2>&1 ;then
		echo "E: Database corrupted! Recreating database..." >&2
		echo "{}" >"$database_location"
	fi
}

#	最新エントリー情報更新
#
#	スナップショットリポジトリ内最新エントリーを更新する
#	$1: スナップショットのUUID [必須]
update_latest()
{
	[ -z "$1" ] && {
		echo "E: ID not specified" >&2
		return 2
	}
	local id="$1"
	dbg_echo "update_latest $id"
	db=$(jq --arg id "$id" 'del(.latest) | . |= { latest: $id } + .' "${database_location}") && echo "$db" >"$database_location"
}

#	最新エントリー情報取得
#
#	スナップショットリポジトリ内最新エントリーを取得する
get_latest()
{
	jq -r '.latest' "${database_location}"
}

#	エントリー追加
#
#	スナップショットリポジトリにエントリーを追加する
#	既に存在する場合は置き換えられる
#	$1: スナップショットのUUID [必須]
#	$2: エントリーの内容(JSON) [必須]
add_entry()
{
	[ -z "$1" ] && {
		echo "E: ID not specified" >&2
		return 2
	}
	[ -z "$2" ] && {
		echo "E: Object not specified" >&2
		return 2
	}
	local id="$1"
	local object="$2"
	dbg_echo "Add entry $id: $object"
	db=$(jq --arg id "$id" --argjson object "$object" 'del(.entries."'"$id"'") | .entries |= . + { ($id): $object }' "${database_location}") && echo "$db" >"$database_location"
}

#	エントリー削除
#
#	スナップショットリポジトリからエントリーを削除する
#	$1: スナップショットのUUID [必須]
remove_entry()
{
	[ -z "$1" ] && {
		echo "E: ID not specified" >&2
		return 2
	}
	local id="$1"
	dbg_echo "remove_entry $id"
	db=$(jq 'del(.entries."'"$id"'")' "${database_location}") && echo "$db" >"$database_location"
}

#	エントリー取得
#
#	スナップショットリポジトリのエントリーを取得する
#	取得したデータは標準出力に流される
#	$1: スナップショットのUUID [必須]
get_entry()
{
	[ -z "$1" ] && {
		echo "E: ID not specified" >&2
		return 2
	}
	local id="$1"
	jq -c '.entries."'"$id"'"' "${database_location}"
}

#	エントリー存在確認
#
#	スナップショットリポジトリ内のエントリーの存在を取得する
#	$1: スナップショットのUUID [必須]
checkexist_entry()
{
	[ -z "$1" ] && {
		echo "E: ID not specified" >&2
		return 2
	}
	local id="$1"
	dbg_echo "checkexist_entry $id"
	[ "$(jq -r ".entries" "${database_location}")" != "null" ] && [ "$(jq -r ".entries | has(\"$id\")" "${database_location}")" == "true" ]
}

#	スナップショット作成
#
#	新しくスナップショットを作成する
#	$1: スナップショットの圧縮方式 [必須]
#		"gzip"(GNU zip), "zstd"(Z Standard), "plain"(無圧縮) から選択
#	$2: ファイル名 [必須]
create_snapshot()
{
	if [ -z "$1" ]; then
		echo "E: Filetype not specified" >&2
		return 2
	fi
	if [ -z "$2" ]; then
		echo "E: File not specified" >&2
		return 2
	fi
	cd "${BACKUP_SOURCE_LOCATION}" || {
		echo "E: Can't access ${BACKUP_SOURCE_LOCATION}" >&2
		return 2
	}

	local comp="$1"
	local filename="$2"

	case "$1" in
		"gzip") {
			if [ "$comp" == "gzip" ] && gzip --version >/dev/null 2>/dev/null; then
				dbg_echo "snapshot filename: $filename"
				tar -czf "${BACKUP_DESTINATION_LOCATION}/$filename" ./*
			else
				echo "E: Can't use $comp" >&2
				return 2
			fi 
		} ;;
		"zstd") {
			if [ "$comp" == "zstd" ] && zstd --version >/dev/null 2>/dev/null; then
				dbg_echo "snapshot filename: $filename"
				tar -cf - ./* | zstd --no-progress -fo "${BACKUP_DESTINATION_LOCATION}/$filename"
			else
				echo "E: Can't use $comp" >&2
				return 2
			fi 
		} ;;
		"plain") {
			dbg_echo "snapshot filename: $filename"
			tar -cf "${BACKUP_DESTINATION_LOCATION}/$filename" ./*
		} ;;
		* ) {
			echo "E: Invalid filetype $comp" >&2
			return 2
		};;
	esac
}

#	スナップショット削除
#
#	スナップショットを削除する
#	$1: スナップショットのUUID [必須]
delete_snapshot()
{
	[ -z "$1" ] && {
		echo "E: ID not specified" >&2
		return 2
	}
	local id="$1"

	local item
	item="$(get_entry "$id")"
	local filename
	filename="$(echo "$item" | jq -r ".filename")"
	dbg_echo "delete ${filename}"
	if [ -n "$BACKUP_DESTINATION_LOCATION" ]; then
		( cd "$BACKUP_DESTINATION_LOCATION" && rm -f "${filename}" )
	else
		rm -f "${filename}"
	fi
}

#	スナップショットの存在確認
#
#	UUIDに紐付けられたスナップショットのデータが存在するかを確認する
#	$1: スナップショットのUUID [必須]
checkexist_snapshot()
{
	[ -z "$1" ] && {
		echo "E: ID not specified" >&2
		return 2
	}
	local id="$1"
	local item
	item="$(get_entry "$id")"
	local filename
	filename="$(echo "$item" | jq -r ".filename")"
	dbg_echo "checking snapshot existence: $id -> $filename"
	[ -f "${BACKUP_DESTINATION_LOCATION}/$filename" ]
}

#	バックアップ保持ルール取得
#
#	バックアップ保持ルールリスト(環境変数:BACKUP_KEEP_RULES)から指定したルールを取得する
#	取得したデータは標準出力に流される
#	$1: ルールの名前 [必須]
get_keeprule()
{
	[ -z "$1" ] && {
		echo "E: Rule not specified" >&2
		exit 1
	}
	local rulename="$1"
	local query_result
	query_result=$(echo "${BACKUP_KEEP_RULES}" | jq -c 'map(select(.name == "'"${rulename}"'"))') || return $?
	[ "$(echo "${query_result}" | jq -r 'length')" == 0 ] && { echo "W: Rule $rulename not found. Returned empty json." >&2; echo "{}"; return 1; }
	[ "$(echo "${query_result}" | jq -r 'length')" -gt 1 ] && { echo "E: Rule $rulename can not be identified. Returned empty json." >&2; echo "{}"; return 2; }
	echo "${query_result}" | jq -c '.[0]'
}

#	バックアップ保持エントリーリスト取得
#
#	バックアップ保持エントリーリストを取得する
#	取得したデータは標準出力に流される
#	$1: ルールの名前 [必須]
get_keeplist()
{
	[ -z "$1" ] && {
		echo "E: Rule not specified" >&2
		return 2
	}
	local rulename="$1"
	jq -c '.keeplist."'"$rulename"'"' "${database_location}"
}

#	バックアップ保持エントリーリスト存在確認
#
#	バックアップ保持エントリーリストの存在を取得する
#	$1: ルールの名前 [必須]
checkexist_keeplist()
{
	[ -z "$1" ] && {
		echo "E: Rule not specified" >&2
		return 2
	}
	local rulename="$1"

	[ "$(jq -r ".keeplist" "${database_location}")" != "null" ] && [ "$(jq -r ".keeplist.\"$rulename\"" "${database_location}")" != "null" ]
}

#	バックアップ保持エントリーリスト更新
#
#	バックアップ保持ルールリストの内容を基に指定した名前の保持エントリーリストを更新する
update_keeplist()
{
	[ -z "$1" ] && {
		echo "E: Rule not specified" >&2
		return 2
	}
	local rulename="$1"
	get_keeprule "$rulename" >/dev/null || {
		echo "W: Error occured when rule loading. Skip." >&2
		return 1
	}
	local data
	if checkexist_keeplist "$rulename"; then
		data="$(get_keeplist "$rulename")"
	else
		data="{}"
	fi

	check_existence()
	{
		dbg_echo "check listitem existence"
		local list
		list="$(echo "$data" | jq -c '.list')"
		local remove_listinfo='false'
		local will_remove='[]'
		[ "$(echo "$list" | jq -r 'length')" -gt 0 ] && {
			for key in $(echo "$list" | jq -r 'keys | .[]')
			do
				local item
				item="$(echo "$list" | jq -r '.['"$key"']')"
				checkexist_entry "$item" || {
					dbg_echo "Entry not found. Remove $item"
					will_remove="$(echo "$will_remove" | jq --argjson index "$key" -c '. |= . + [ $index ]')"
					[ "$key" -eq 0 ] &&
					{
						remove_listinfo='true'
					}
				}
			done
		}
		dbg_echo "will remove: $will_remove"
		[ "$(echo "$will_remove" | jq -r 'length')" -gt 0 ] && list="$(echo "$list" | jq -c 'del(.'"$will_remove"')')"
		[ "$remove_listinfo" == "true" ] && data="$(echo "$data" | jq -c 'del(.lastadd)')"
		data="$(echo "$data" | jq -c --argjson list "$list" 'del(.list) | . |= . + { $list }')"
	}
	[ "$(echo "$data" | jq -c '.list')" != "null" ] && check_existence

	fetchandadd_latest()
	{
		local latest_id
		latest_id="$(get_latest)"
		[ "$latest_id" == "null" ] && {
			dbg_echo "Latest tag not found. skip"
			return
		}
		[ "$(echo "$data" | jq -r 'map(select(. == "'"$latest_id"'")) | length | . != 0')" == "true" ] && {
			dbg_echo "$latest_id already added. skip"
			return
		}
		local latest_entry
		latest_entry="$(get_entry "$latest_id")"
		local rule
		rule="$(get_keeprule "$rulename")"
		local fetch_result
		fetch_result='true'

		local duration
		duration="$(echo "$rule" | jq -c '.duration | numbers')"
		[ -n "$duration" ] && {
			dbg_echo "duration filter: $duration"
			[ "$fetch_result" == "true" ] && {
				if [ "$(echo "$data" | jq -r '.lastadd')" == "null" ]; then
					dbg_echo "Last addition data not found. Return true"
					fetch_result='true'
				elif [ "$(echo "{}" | jq --argjson duration "$duration" --argjson keeplist "$data" --argjson latest "$latest_entry" '{ $duration, $keeplist, $latest } | .keeplist.lastadd.second + .duration < .latest.createtime.second or ( .keeplist.lastadd.second + .duration == .latest.createtime.second and .keeplist.lastadd.nanosec + .duration <= .latest.createtime.nanosec)')" == "true" ]; then
					dbg_echo "Match duration filter. Return true"
					fetch_result='true'
				else
					dbg_echo "Not match duration filter. Return false"
					fetch_result='false'
				fi
			}
		}
		[ "$fetch_result" == "true" ] && {
			data="$(echo "$data" | jq --arg id "$latest_id" --argjson lastadd_sec "$(echo "$latest_entry" | jq '.createtime.second')" --argjson lastadd_ns "$(echo "$latest_entry" | jq '.createtime.nanosec')" '.list |= [ $id ] + . | del(.lastadd) | . |= . + { lastadd: { second: $lastadd_sec, nanosec: $lastadd_ns } }')"
		}
	}
	fetchandadd_latest

	filter_list()
	{
		local rule
		rule="$(get_keeprule "$rulename")"
		local keep_entry
		keep_entry="$(echo "$rule" | jq -c '.keep_entry | numbers')"
		[ -n "$keep_entry" ] && {
			[ "$(echo "$data" | jq -r '.list | length')" -gt "$keep_entry" ] && {
				data="$(echo "$data" | jq -c 'del(.list['"$keep_entry"':])')"
			}
		}
	}
	filter_list
	db=$(jq --arg id "$rulename" --argjson data "$data" 'del(.keeplist."'"$rulename"'") | .keeplist |= . + { ($id): $data }' "${database_location}") && echo "$db" >"$database_location"
}

autoremove()
{
	local entrylist
	entrylist="$(jq -c '.entries | keys' "${database_location}")"
	local keeplist="[]"
	for item in $(echo "$BACKUP_KEEP_RULES" | jq -r '.[].name')
	do
		keeplist="$(echo "$keeplist" | jq -c --argjson addlist "$(get_keeplist "$item" | jq -c '.list')" '. |= . + $addlist' )"
	done
	keeplist="$(echo "$keeplist" | jq -c 'unique')"
	dbg_echo "autoremove: keeplist=$keeplist"
	for item in $(echo "$entrylist" | jq -r '.[]')
	do
		dbg_echo "autoremove: Checking $item"
		[ "$(echo "$keeplist" | jq -c 'map(select( . == "'"$item"'" )) | length')" -eq 0 ] && {
			dbg_echo "autoremove: Deleting $item"
			delete_snapshot "$item"
			remove_entry "$item"
		}
	done
}

backup()
{
	local create_time_formated
	create_time_formated=$(date +%Y%m%d_%H%M%S_%N)
	local create_time_second
	create_time_second=$(date +%s)
	local create_time_nanosec
	create_time_nanosec=$(date +%N)
	local id
	while :
	do
		id=$(get_uuid)
		checkexist_entry "$id" || break
	done

	echo "Creating..."
	if [ "$BACKUP_COMPRESSION_METHOD" == "gzip" ]; then
		local backup_name="backup-${create_time_formated}.tgz"
	elif [ "$BACKUP_COMPRESSION_METHOD" == "zstd" ]; then
		local backup_name="backup-${create_time_formated}.tzst"
	elif [ "$BACKUP_COMPRESSION_METHOD" == "plain" ]; then
		local backup_name="backup-${create_time_formated}.tar"
	else
		echo "E: Invalid comporession method" >&2
		return 2
	fi
	(create_snapshot "$BACKUP_COMPRESSION_METHOD" "$backup_name") || return 1

	echo "Registing..."
	dbg_echo "ID: $id"
	add_entry "$id" "$(echo "{}" | jq -c --arg filename "$backup_name" --argjson createtime_sec "${create_time_second:-0}" --argjson createtime_ns "${create_time_nanosec:-0}" '{ filename: $filename, createtime: { second: $createtime_sec, nanosec: $createtime_ns } }')" || return 1
	update_latest "$id" || return 1
}

update()
{
	echo "Updating..."
	if [ "$(jq -r ".entries" "${database_location}")" != "null" ]; then
		for item in $(jq -r '.entries | keys | .[]' "$database_location")
		do
			if ! checkexist_snapshot "$item"; then
				remove_entry "$item"
			fi
		done
	fi
	[ "$(echo "$BACKUP_KEEP_RULES" | jq -r "arrays | length")" -gt 0 ] && {
		for item in $(echo "$BACKUP_KEEP_RULES" | jq -r '.[].name')
		do
			update_keeplist "$item"
		done
		autoremove
	}
}

init || exit
backup || exit
update || exit
