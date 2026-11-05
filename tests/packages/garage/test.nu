# Garage as the release tool's tests use it: one node on loopback, a layout, a key and a bucket
# the key may write. The S3 path itself (rclone against this node) is tested where the release tool
# is; here only the server and its admin CLI. Needs a loopback interface, which the sandbox has.
use checks.nu *
let garage = $"($env.pkg)/bin/garage"
let t = $"($env.TMPDIR? | default /tmp)/garage-test"
rm -rf $t
mkdir $t
let conf = $"($t)/garage.toml"
[
  $'metadata_dir = "($t)/meta"'
  $'data_dir = "($t)/data"'
  'db_engine = "lmdb"'
  'replication_factor = 1'
  'rpc_bind_addr = "127.0.0.1:3901"'
  'rpc_public_addr = "127.0.0.1:3901"'
  'rpc_secret = "4425f5c26c5e11581d3223904324dcb5b5d5dfb14e5e7f35e38c595424f5f1e6"'
  ''
  '[s3_api]'
  's3_region = "garage"'
  'api_bind_addr = "127.0.0.1:3900"'
  'root_domain = ".s3.garage.localhost"'
] | str join "\n" | save $conf

# "garage cargo:2.5.0 [features: lmdb, system-libs]"
let v = (^$garage --version | str trim)
assert $"version is the pin, with the features of the build: ($v)" ($v == "garage cargo:2.5.0 [features: lmdb, system-libs]")

let pid = (^sh -c $"'($garage)' -c '($conf)' server > '($t)/server.log' 2>&1 & echo $!" | str trim)
mut up = false
for _ in 1..60 {
  if ((do { ^$garage -c $conf status } | complete).exit_code == 0) { $up = true; break }
  sleep 500ms
}
assert $"the server answers: (open --raw $'($t)/server.log' | lines | last 5 | str join '; ')" $up

let id = (^$garage -c $conf node id -q | str trim | split row "@" | first)
^$garage -c $conf layout assign -z dc1 -c 1G $id
^$garage -c $conf layout apply --version 1
assert "the layout has the node" ((^$garage -c $conf layout show) | str contains ($id | str substring 0..15))

let key = (^$garage -c $conf key create release-test)
assert "a key is made" ($key | str contains "GK")
^$garage -c $conf bucket create updates
^$garage -c $conf bucket allow --read --write updates --key release-test
let info = (^$garage -c $conf bucket info updates)
assert "the key may write the bucket" ($info | str contains "release-test")

^kill $pid
rm -rf $t
done
