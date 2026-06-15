# vps

我的 VPS 一鍵裝機腳本:建立 sudo 管理員帳號、SSH 加固(改 port、停掉密碼登入只留金鑰)、安裝並設定 zsh(antidote + powerlevel10k)與 tmux。

支援 Debian / Ubuntu、openSUSE / SLES、Gentoo,自動偵測 init 系統(systemd / OpenRC / SysV)。

## 安全前提:一定要先有 SSH 金鑰

這支腳本會關閉密碼 SSH 登入,只留公鑰登入。所以它在**做任何事情之前**,會先檢查要部署的 `authorized_keys` 裡確實有一把合法公鑰:

- 找不到金鑰 → **立刻中止,系統一字不改**(不裝套件、不建帳號、不碰 sshd)。
- 預設來源是「呼叫者」的 `~/.ssh/authorized_keys`(透過 sudo 跑時是你登入的那個帳號,不是 root)。

所以執行前先確認自己有金鑰,例如:

```bash
install -d -m700 ~/.ssh
curl -fsSL https://github.com/<你的GitHub帳號>.keys >> ~/.ssh/authorized_keys
```

## 一行安裝

curl:

```bash
curl -fsSL https://raw.githubusercontent.com/Zakkaus/vps/main/vps-bootstrap.sh | sudo bash
```

wget:

```bash
wget -qO- https://raw.githubusercontent.com/Zakkaus/vps/main/vps-bootstrap.sh | sudo bash
```

## 這支腳本實際做了什麼

依序執行,只要金鑰檢查沒過就整個不會跑:

1. 確認是 root（或 sudo）執行。
2. 解析金鑰來源 `SRC_AUTH_KEYS`(預設為呼叫者的 `~/.ssh/authorized_keys`),並驗證裡面有合法公鑰；沒有就中止,系統不變。
3. 偵測發行版與 init 系統。
4. 安裝套件:`sudo git curl wget zsh tmux vim openssl ca-certificates fzf`。
5. 建立管理員帳號:預設 shell 為 zsh,加入 sudo 群組(Debian 系是 `sudo`、openSUSE/Gentoo 是 `wheel`),設定隨機密碼。帳號名稱與密碼預設隨機產生。
6. 把你的金鑰部署成新帳號的 `~/.ssh/authorized_keys`(權限 700/600)。
7. 設定 sudo 免密碼:寫入 `/etc/sudoers.d/99-admin-nopasswd`,並確保 `/etc/sudoers` 有讀取 `sudoers.d`,改完用 `visudo -c` 驗證,失敗自動回滾。
8. SSH 加固,寫入 `/etc/ssh/sshd_config.d/99-bootstrap-security.conf`:
   - `Port`（預設 61000）
   - `PasswordAuthentication no`、`KbdInteractiveAuthentication no`、`ChallengeResponseAuthentication no`
   - `PubkeyAuthentication yes`、`PermitRootLogin prohibit-password`
   - 缺 host key 先 `ssh-keygen -A`;舊版 sshd_config 沒有 `Include` 行就補上;用 `sshd -t` 驗證,失敗則移除剛寫的 drop-in 並中止(不留壞掉的 sshd)。
   - Debian/Ubuntu 若是 `ssh.socket` socket activation,額外覆寫 socket 的監聽 port(否則改 port 無效)。
9. 寫入 `~/.tmux.conf`:prefix 改 `C-a`、滑鼠、vi copy mode、好看的狀態列。
10. 寫入 `~/.zshrc` 並以管理員身分安裝 antidote + powerlevel10k + fzf-tab + zsh-autosuggestions + zsh-completions;打包成 `~/.cache/zsh/antidote.zsh`,並驗證打包檔非空(失敗會明確報錯)。
11. 依 init 系統 enable 並重啟 SSH,最後印出帳號、密碼與登入指令。

腳本**不會**做的事:不裝防火牆、不裝 fail2ban、不改 root 密碼、不刪任何現有使用者、不碰你現有的 SSH 連線設定(改完前舊 session 仍可用)。

## 自訂參數

用環境變數覆寫預設值,注意要放在 `sudo` 後面才會傳進去:

```bash
curl -fsSL https://raw.githubusercontent.com/Zakkaus/vps/main/vps-bootstrap.sh \
  | sudo SSH_PORT=2222 ADMIN_USER=zakk bash
```

| 變數 | 說明 | 預設值 |
| --- | --- | --- |
| `SSH_PORT` | SSH 監聽 port | `61000` |
| `ADMIN_USER` | 管理員帳號名稱 | `admin<隨機>` |
| `ADMIN_PASS` | 管理員密碼 | 隨機產生 |
| `SRC_AUTH_KEYS` | 來源 `authorized_keys` 路徑 | 呼叫者的 `~/.ssh/authorized_keys` |

## 只修 zsh(提示字元變回 `localhost%` 時)

如果登入後提示字元是裸的 `localhost%` 而不是 powerlevel10k,代表 antidote 打包檔沒生成(裝外掛當下網路有問題)。用你的一般帳號(不是 root)單獨重跑這支即可,冪等、不碰 SSH:

curl:

```bash
curl -fsSL https://raw.githubusercontent.com/Zakkaus/vps/main/zsh-setup.sh | bash && exec zsh
```

wget:

```bash
wget -qO- https://raw.githubusercontent.com/Zakkaus/vps/main/zsh-setup.sh | bash && exec zsh
```

跑完執行 `p10k configure` 設定提示字元外觀。

## 完成後務必驗證

關掉目前這個 session 之前,先開一個新終端測試新登入能不能進:

```bash
ssh -p 61000 <ADMIN_USER>@YOUR_SERVER_IP
sudo -n id        # 應該不用密碼
tmux
p10k configure
```

密碼 SSH 登入已被關閉,在新登入確認可用之前,不要關掉目前的 session。

## 手動安裝(不想用 pipe)

```bash
curl -fsSL https://raw.githubusercontent.com/Zakkaus/vps/main/vps-bootstrap.sh -o vps-bootstrap.sh
chmod +x vps-bootstrap.sh
sudo ./vps-bootstrap.sh
```

## License

[MIT](LICENSE)
