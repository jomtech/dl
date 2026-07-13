#!/bin/bash

# スクリプトの堅牢性を高める設定
set -euo pipefail

# --- 初期設定 ---
ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:127.0) Gecko/20100101 Firefox/127.0"

# 引数の解析
SERIAL_MODE=false
LOCAL_M3U8=""
args=()
while [[ $# -gt 0 ]]; do
  case $1 in
    -s|--serial) SERIAL_MODE=true; shift ;;
    -l|--local-m3u8) LOCAL_M3U8="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

if [ ${#args[@]} -ne 2 ]; then
  echo "使用法: $0 [-s|--serial] [-l|--local-m3u8 <file>] <m3u8_url> <output_filename_without_extension>"
  exit 1
fi

m3u8_url=${args[0]}
url_basename=${m3u8_url%/*}
m3u8_file_name=${m3u8_url##*/}
m3u8_file_name="${m3u8_file_name%%\?*}"

output_file="${args[1]}.mp4"
output_dir="${GITHUB_WORKSPACE:-$(pwd)}"
final_output_path="$output_dir/$output_file"
referer="https://turbovidhls.com/"
output_basename=$(basename "$output_file" .mp4)

# --- RAMディスクを作業領域にする ---
WORK_DIR="$output_dir/m3u8_work_$output_basename"

# クリーンアップ関数（スクリプト終了時にRAMを解放する）
cleanup() {
    if [ -d "$WORK_DIR" ]; then
        echo "RAM上の作業データを削除しています..."
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

# 作業ディレクトリ作成
mkdir -p "$WORK_DIR"
echo "作業ディレクトリ(RAM): $WORK_DIR"
echo "最終出力ファイル: $final_output_path"

# --- 処理完了チェック ---
if [ -f "$final_output_path" ]; then
    echo "出力ファイルが既に存在するため終了します: $final_output_path"
    exit 0
fi

# --- ステップ1: m3u8解析 & リスト作成 ---
url_list_file="$WORK_DIR/url_list.txt"
rename_list_file="$WORK_DIR/rename_list.txt"
downloaded_m3u8_file="$WORK_DIR/$m3u8_file_name"

echo "ステップ1: m3u8ダウンロードと解析..."

# m3u8を取得
if [ -n "$LOCAL_M3U8" ]; then
    echo "ローカルのm3u8ファイルを使用します: $LOCAL_M3U8"
    cp "$LOCAL_M3U8" "$downloaded_m3u8_file"
else
    if [[ "$m3u8_url" == *"://fc2stream.tv"* ]]; then
        aria2c -d "$WORK_DIR" -o "$m3u8_file_name" "$m3u8_url" \
            --header='Host: fc2stream.tv' \
            --header='User-Agent: Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:152.0) Gecko/20100101 Firefox/152.0' \
            --header='Accept: */*' \
            --header='Accept-Language: ja,en-US;q=0.9,en;q=0.8' \
            --header='Accept-Encoding: gzip, deflate, br, zstd' \
            --header='Sec-GPC: 1' \
            --header='Connection: keep-alive' \
            --header='Referer: https://fc2stream.tv/e/akoskkssjf94' \
            --header='Cookie: _ga_2TL7NH453R=GS2.1.s1783212093$o1$g0$t1783212093$j60$l0$h0; _ga=GA1.1.1116863472.1783212093; _ga_E2BG6CPV2J=GS2.1.s1783212093$o1$g0$t1783212093$j60$l0$h0' \
            --header='Sec-Fetch-Dest: empty' \
            --header='Sec-Fetch-Mode: cors' \
            --header='Sec-Fetch-Site: same-origin' \
            --header='TE: trailers'
    else
        aria2c -d "$WORK_DIR" -o "$m3u8_file_name" "$m3u8_url"
    fi
fi
count=0
while read -r line; do
    # コメント行や空行をスキップ
    [[ "$line" =~ ^# ]] && continue
    [[ -z "$line" ]] && continue

    # URLの正規化
    if [[ "$line" =~ ^http ]]; then
        full_url="$line"
    else
        full_url="$url_basename/$line"
    fi
    echo "$full_url" >> "$url_list_file"

    # ファイル名抽出（クエリ除去）
    file="${line##*/}"
    file="${file%%\?*}"

    # リネームリスト作成: 元ファイル名 [スペース] 連番TSファイル名
    echo "$file $(printf %05d $count).ts" >> "$rename_list_file"

    count=$((count + 1))
done < "$downloaded_m3u8_file"

# --- ステップ2: RAMへのダウンロード ---
if [ "$SERIAL_MODE" = true ]; then
    echo "ステップ2: RAMへの直列ダウンロード開始 (429回避モード, セグメント数: $count)..."
    while read -r url; do
        aria2c \
          --file-allocation=none \
          -c \
          -j 1 -x 1 -s 1 \
          "$url" \
          -d "$WORK_DIR" \
          --header="Referer: $referer" \
          -U "$ua" \
          --console-log-level=warn \
          --summary-interval=0
        sleep 1
    done < "$url_list_file"
else
    echo "ステップ2: RAMへの並列ダウンロード開始 (セグメント数: $count)..."
    aria2c \
      --file-allocation=none \
      -c \
      -j 32 \
      -x 16 \
      -s 16 \
      --input-file="$url_list_file" \
      -d "$WORK_DIR" \
      --header="Referer: $referer" \
      -U "$ua" \
      --console-log-level=warn \
      --summary-interval=0
fi

# --- ステップ3: [高速化] 変換・リネーム・削除のパイプライン処理 ---
echo "ステップ3: RAM上で変換処理 (Tail処理) を実行中..."

# GNU Parallelを使用。
# {1}: 元ファイル名, {2}: 出力TSファイル名
cat "$rename_list_file" | parallel --colsep ' ' -j+0 "
    if [ -f $WORK_DIR/{1} ]; then
        # 先頭9バイトを削って .ts として保存 (RAM to RAM)
        tail -c +10 $WORK_DIR/{1} > $WORK_DIR/{2}
        # メモリ節約のため、変換が終わった元ファイルは即座に削除
        rm $WORK_DIR/{1}
    fi
"

# --- ステップ4: 結合 (RAM -> RAM) ---
echo "ステップ4: 結合してMP4を作成..."

ffmpeg_list_file="$WORK_DIR/list.txt"
find "$WORK_DIR" -name "*.ts" | sort | sed 's/^/file /' > "$ffmpeg_list_file"

if [ ! -s "$ffmpeg_list_file" ]; then
    echo "エラー: TSファイルが見つかりません。"
    exit 1
fi

ffmpeg -f concat -safe 0 -i "$ffmpeg_list_file" -c copy -movflags +faststart "$final_output_path" -loglevel error -stats
find "$WORK_DIR" -name "*.ts" | xargs rm

# --- ステップ5: ファイル名秘匿とage暗号化 ---
echo "ステップ5: ファイル名を秘匿し、ageで暗号化中..."

if ! command -v age &> /dev/null; then
    echo "エラー: ageコマンドが見つかりません。sudo apt install age でインストールしてください。"
    exit 1
fi

# HF上でファイル名がバレないよう、ランダムな文字列にする
SECURE_BASENAME=$(($RANDOM % 100))_$(openssl rand -hex 8)
TAR_PATH="$WORK_DIR/${SECURE_BASENAME}.tar"
AGE_PATH="$WORK_DIR/${SECURE_BASENAME}.age"

# 元のファイル名を維持・隠蔽するためにtarでまとめる
tar -cf "$TAR_PATH" -C "$output_dir" "$output_file"
rm "$final_output_path"

age -R ./recipient.txt -o "$AGE_PATH" "$TAR_PATH"

# WORK_DIRは終了時に削除されるため、完成したageファイルをoutput_dirへ移動する
FINAL_AGE_PATH="$output_dir/$(basename "$AGE_PATH")"
mv "$AGE_PATH" "$FINAL_AGE_PATH"

if [ "${SKIP_UPLOAD:-false}" = "true" ]; then
    echo "アップロードをスキップしました。出力ファイル: $FINAL_AGE_PATH"
    if [ -n "${GITHUB_ENV:-}" ]; then
        echo "AGE_FILE_PATH=$FINAL_AGE_PATH" >> "$GITHUB_ENV"
        echo "AGE_FILE_NAME=$(basename "$FINAL_AGE_PATH")" >> "$GITHUB_ENV"
    fi
else
    echo "Hugging Faceへ暗号化ファイル（$(basename "$FINAL_AGE_PATH")）をアップロード中..."
    hf upload jomdel0/ud-open "$FINAL_AGE_PATH" --repo-type=dataset
    echo "完了: $FINAL_AGE_PATH をアップロードしました。"
    # アップロードが完了したらローカルのファイルは削除する（任意）
    # rm "$FINAL_AGE_PATH"
fi

# trapにより終了時に作業用ディレクトリは自動削除されます。
