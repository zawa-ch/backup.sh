# example

`backup.sh` を実用するために利用可能なテンプレート

## 概要

example ディレクトリ以下には、 `backup.sh` を実際の環境で利用するために使うことができるテンプレートを配置しています。

## `dockerfile` ディレクトリ

`dockerfile` ディレクトリは、 Docker を使用して alpine イメージ内に `backup.sh` を配置して定期的にバックアップを実行できるようにするためのサンプルです。

このサンプルでは、ビルド時に以下の操作を行います。

- 必要となるパッケージのインストール
- `backup.sh` を `/usr/share/backup` に配置する
- `startup.sh` を `/` に配置する
- `/usr/bin/backup` を `/usr/share/backup/backup.sh` にリンクする
- `cron.txt` の内容をcrontabに登録する

実行するには`dockerfile` ディレクトリ内で以下のコマンドを入力します。
`<source>` にはバックアップしたいディレクトリを、 `<destination>` には作成したスナップショットを管理するためのディレクトリを絶対パスで指定します。

```bash
$ docker build -t backup ./
$ docker run -l backup_1 -v /source:<source>:ro -v /destination:<destination> backup
```

環境変数を設定することによって `backup.sh` の挙動を変更することもできます。`docker run`を実行する際に `--env` オプションをつけてみてください。

```bash
$ docker build -t backup ./
$ docker run -l backup_1 -v /source:<source>:ro -v /destination:<destination> --env BACKUP_COMPRESSION_METHOD=gzip backup
```

コンテナ実行中に手動でバックアップを実行するには以下のコマンドを入力します。

```bash
$ docker exec backup_1 backup
```
