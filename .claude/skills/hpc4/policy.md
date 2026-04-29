# HPC4 接続規約 — ITSO 公式準拠の参照ドキュメント

このファイルは HKUST ITSO が公開している HPC4 cluster の接続規約のうち、本 skill が依拠している部分を記録したもの。SKILL.md は運用最小限のみとし、規約の正確な根拠が必要になった時のみこのファイルを参照する。

## 出典

- [HPC4 - HOW TO LOGIN](https://itso.hkust.edu.hk/services/academic-teaching-support/high-performance-computing/hpc4/login)
- [Off-Campus Wi-Fi Connection for Campus Community](https://itso.hkust.edu.hk/services/general-it-services/wifi/off-campus-wi-fi)
- [HKUST Hotspot Locations](https://itso.hkust.edu.hk/services/general-it-services/wifi/hotspot-locations)
- [Secure Remote Access (VPN) Overview](https://itso.hkust.edu.hk/services/cyber-security/vpn/overview)

最終確認: 2026-04-29

## HPC4 への接続パス（ITSO 公式）

ITSO HPC4 login ページに明記されている接続要件：

| 場面 | 必要な接続 |
|---|---|
| **on-campus** | wired connection または "eduroam" Wi-Fi |
| **off-campus** | Secure Remote Access (VPN) |

ここで言う "Secure Remote Access (VPN)" は **Ivanti Secure Access** クライアントを指す（ITSO VPN overview ページより。旧名 Pulse Secure）。

VPN overview ページの記述：

> "When connected, you will be assigned with a HKUST IP address instead of the one at home or while traveling, enabling access to restricted campus resources."

つまり Ivanti は HKUST の 143.89/16 IP を割り当てる。**HPC4 (143.89.184.3) は HKUST IP からしか到達できない**ので、これが skill が判定基準にしている事実の出所。

## "on-campus" の境界 — eduroam の federated 性質

ITSO の Hotspot Locations ページが列挙する HKUST eduroam の coverage は **HKUST 物理キャンパス内** のみ：

> Common Areas (amphitheater, piazzas, sports facilities, fountains, bus stops), Shaw Auditorium, Catering Outlets, Lee Shau Kee Library, Teaching Venues, Office Areas, Laboratory Areas, Car Parks, Student Halls

一方 eduroam は federated roaming service であり、**HKUST 以外の機関でも同じ SSID で繋がる**：

- 他大学（PolyU, CityU, HKU 等）
- HKSTP の施設（**Data Technology Hub at TKO InnoPark** など）
- 多くの空港・駅
- 海外の多くの大学

これらの場所で eduroam に HKUST アカウントで認証して繋がっても、配布される IP はその施設の NAT pool（例：DT Hub では `172.22/16`）であり HKUST の `143.89/16` ではない。**ITSO 視点ではこれは "off-campus" 扱い** であり、HPC4 へ届くにはそこから別途 Ivanti VPN を張る必要がある。

「eduroam に繋がっている」と「HKUST 圏内に居る」は別物、というのがこの規約の最も非自明な点。

### 本 skill の判定基準との対応

本 skill は「IF が `143.89/16` IPv4 を持っているか」だけで HKUST 圏内を判定する（`scripts/common.sh::find_hkust_iface` / `iface_has_hkust_ip`）。これは上記の federated 問題を一発で正しく弾くための設計：

| 場所・経路 | IF が持つ IP | skill 判定 | ITSO 規約上の扱い |
|---|---|---|---|
| HKUST キャンパス内 eduroam | 143.89/16 | ok | on-campus |
| HKUST 有線 | 143.89/16 | ok | on-campus |
| Ivanti SSL VPN（どこからでも） | utun に 143.89/16 | ok | off-campus 救済策 |
| DT Hub eduroam | 172.22/16 | ng | off-campus（規約上 Ivanti が必要） |
| 他大学 eduroam | その大学の pool | ng | off-campus |
| 自宅 ISP 直 | 公衆 IPv4 | ng | off-campus |

## 認証

ITSO HPC4 login ページの認証要件：

1. **Password + Duo MFA**：username（domain suffix なし）+ password を入れた後、Duo authentication method を選択
2. **SSH key authentication**：公開鍵を `~/.ssh/authorized_keys` に登録すれば password と Duo の両方が省略される

本 skill は (2) を前提とし、`ssh-copy-id` による公開鍵登録を setup フローに組み込んでいる。

## skill 内での扱い

このファイルの内容は SKILL.md には**重複させない**。SKILL.md は運用最小限のみとし、規約の根拠や周辺事情が必要になった時に Claude / user がこのファイルを開く。
