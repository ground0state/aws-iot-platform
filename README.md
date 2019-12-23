# AWS IoT プラットフォーム

## 環境変数

AWS のアクセスキーと使用するリージョンを環境変数に設定する。

```bash
SET AWS_ACCESS_KEY_ID=...
SET AWS_SECRET_ACCESS_KEY=...
SET AWS_DEFAULT_REGION=...
```

## プレフィックス

`variables.tf`の中の prefix を好きな値に置き換える。

```tf
variable "prefix" {
  default = "prefix"
}
```

## 構築

Terraform を初期化する。

```bash
terraform init
```

構築されるリソースを表示する。

```bash
terraform plan
```

構築実行。y/n を聞かれるので、`yes`と打ち込む。

```bash
terraform apply
```

構築完了後、S3 バケット名と Kibana のエンドポイントが標準出力に出力される。

```bash
api_bucket_name = ...
elasticsearch_backup_bucket_name = ...
error_bucket_name = ...
kibana_endpoint = search-XXXXX-es-xxxxxxxxxxxxxxxxxxxxxxxx.xx-xxxx-x.es.amazonaws.com/\_plugin/kibana/
```

コマンドで全て削除できる。

```bash
terraform destroy
```

## API ユーザー登録

AWS コンソールを開く。Cognito ユーザープールを開くと「"プレフィックス"-iot-pool」が作成されているので、適宜ユーザーを登録する。また、アプリクライアントも作成する。

## API の使い方

`id` でデバイス id を指定する（デバイス id は MQTT クライアントの id）。`datetime`はサーバの受信時刻で、UNIXTIME で表される。

id 指定で一件取得。

```json
query {
    getIOTDATA(id: "abeta-20191118_Core-c00", datetime: 1574058304){
            id
            unixTimestamp
    }
}
```

最新のレコードを一件取得。

```json
query {
    getLatestIOTDATA(id: "abeta-20191118_Core-c00"){
        items{
            id
            unixTimestamp
        }
    }
}
```

レコード一覧取得。

```json

query {
    listIOTDATAS(filter:{id: {eq: "abeta-20191118_Core-c00"}, datetime: {lt: 1574058304}}, limit:1000){
    items{
        id
    }
        nextToken
    }
}
```

## ToDo

- ヒアテキストになっているパラメータ部分を外部ファイルに切り出す
- アカウント ID に依存するパラメータの ID 依存を無くす
- GraphQL の機能を増やす
- Elasticsearch 内のデータ削除
- 時刻表示を UNIXTIME でない表示にする
