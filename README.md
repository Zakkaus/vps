# vps

我的 VPS 一鍵裝機腳本:建立 sudo 管理員帳號、SSH 加固(改 port、停密碼登入只留金鑰)、安裝並設定 zsh(antidote + powerlevel10k)與 tmux。

支援 **Debian / Ubuntu**、**openSUSE / SLES**、**Gentoo**(自動偵測 systemd / OpenRC / SysV)。

## 一行安裝

> ⚠️ 跑之前,先確認你**目前登入的使用者** `~/.ssh/authorized_keys` 已經有公鑰。
> 腳本會把這把金鑰裝到新帳號;**找不到金鑰就會中止**(避免關掉密碼登入後把自己鎖在外面)。

curl:

```bash
curl -fsSL https://raw.githubusercontent.com/Zakkaus/vps/main/vps-bootstrap.sh | sudo bash
```

wget:

```bash
wget -qO- https://raw.githubusercontent.com/Zakkaus/vps/main/vps-bootstrap.sh | sudo bash
```

## 自訂參數

用環境變數覆寫預設值(注意要放在 `sudo` 後面才會傳進去):

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

## 腳本做了什麼

- 安裝 `sudo git curl zsh tmux vim openssl ca-certificates fzf`
- 建立 zsh 為預設 shell 的管理員帳號,加入 sudo 群組並設定 **NOPASSWD**
- 從你現有的金鑰部署 `authorized_keys`(**沒有金鑰就中止,不會把你鎖出去**)
- SSH 加固:改 port、`PasswordAuthentication no`、`PermitRootLogin prohibit-password`,並處理 Debian/Ubuntu 的 `ssh.socket` socket activation
- 寫入 `.tmux.conf`(prefix 改 `C-a`、滑鼠、vi copy mode、好看的狀態列)
- 寫入 `.zshrc` 並裝好 antidote + powerlevel10k + fzf-tab + autosuggestions

## 只修 zsh(提示字元變回 `localhost%` 時)

如果登入後提示字元是裸的 `localhost%` 而不是 powerlevel10k,代表 antidote bundle 沒生成(裝外掛當下網路有問題)。**用你的一般帳號**(不是 root)單獨重跑這支即可,它是冪等的、不碰 SSH:

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

關掉目前這個 session **之前**,先開一個**新終端**測試新登入能不能進:

```bash
ssh -p 61000 <ADMIN_USER>@YOUR_SERVER_IP
sudo -n id        # 應該不用密碼
tmux
p10k configure
```

密碼 SSH 登入已被關閉 —— 在新登入確認可用之前,**不要關掉目前的 session**。

## 手動安裝(不想用 pipe)

```bash
curl -fsSL https://raw.githubusercontent.com/Zakkaus/vps/main/vps-bootstrap.sh -o vps-bootstrap.sh
chmod +x vps-bootstrap.sh
sudo ./vps-bootstrap.sh
```

## License

[MIT](LICENSE)
