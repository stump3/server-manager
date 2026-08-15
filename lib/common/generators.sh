# shellcheck shell=bash
# common/generators.sh — secret/password/username generators

gen_secret()    { openssl rand -hex 16; }
gen_hex64()     { openssl rand -base64 96 | tr -dc 'a-zA-Z0-9' | head -c 64; }
gen_password()  {
    local p=""
    p+=$(tr -dc 'A-Z'    </dev/urandom | head -c 1)
    p+=$(tr -dc 'a-z'    </dev/urandom | head -c 1)
    p+=$(tr -dc '0-9'    </dev/urandom | head -c 1)
    p+=$(tr -dc '!@#%^&*' </dev/urandom | head -c 3)
    p+=$(tr -dc 'A-Za-z0-9!@#%^&*' </dev/urandom | head -c 18)
    echo "$p" | fold -w1 | shuf | tr -d '\n'
}
gen_user()      { tr -dc 'a-zA-Z' </dev/urandom | head -c 8; }
