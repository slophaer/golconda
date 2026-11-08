# age as golconda vars uses it (cli/src/vars.rs): age-keygen makes a key, -e -R
# encrypts to its recipients file, -d -i decrypts with the identity; another identity fails.
use checks.nu *
let bin = $"($env.pkg)/bin"
let t = $"($env.TMPDIR? | default /tmp)/age-test"
rm -rf $t
mkdir $t
cd $t

assert "version is the pin" ((^$"($bin)/age" --version | str trim) == "v1.3.2")
^$"($bin)/age-keygen" -o key.txt
^$"($bin)/age-keygen" -o other.txt
^$"($bin)/age-keygen" -y key.txt | save recipients.txt
assert "the recipient is an age public key" ((open recipients.txt | str trim) starts-with "age1")

"a host certificate\n" | save value
^$"($bin)/age" -e -R recipients.txt -o value.age value
assert "the stored file is not the value" ((open --raw value.age) != (open --raw value))
let out = (^$"($bin)/age" -d -i key.txt value.age | complete)
assert "decrypts to the same bytes" ($out.exit_code == 0 and $out.stdout == "a host certificate\n")
assert "another identity cannot decrypt" ((^$"($bin)/age" -d -i other.txt value.age | complete).exit_code != 0)
cd /
rm -rf $t
done
