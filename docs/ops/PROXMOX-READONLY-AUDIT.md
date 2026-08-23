# Proxmox — read-only аудит стенда OUO

## Фактический статус 2026-08-23

- read-only API token работает; секрет не записан в Git;
- целевой host только `pve2`, PVE `9.1.1`, kernel `6.17.2-1-pve`;
- 16 logical CPU, 47 GiB RAM, около 42.6 GiB available на момент аудита;
- `local-lvm`: около 320 GB available; `local`: около 89.7 GB available;
  shared NFS `cluster`: около 21.5 TB available;
- bridge `vmbr0`: `192.168.100.3/24`, gateway `192.168.100.1`, uplink `nic0`;
- доступны Debian 12.13 netinst ISO и Debian 12 standard LXC template;
- PVE2 не пустой: работают VM 106 и LXC 201–212/301–312. Они исключены из
  scope любых изменений;
- следующий cluster VMID API возвращает `107`;
- предложена отдельная VM 107: 6 vCPU, 12 GiB RAM, 80 GiB `local-lvm`, VirtIO
  `vmbr0`, Debian 12 genericcloud. Создание ещё не выполнялось.

## Исторический статус 2026-08-19

- ранее указанный endpoint `https://87.249.8.218:10002` доступен и отвечает
  HTTP `200`;
- TLS certificate не проходит публичную trust-chain проверку
  (`ssl_verify_result=20`), поэтому fingerprint/issuer нужно сверить отдельно;
- предоставленный API token распознан сервером, но авторизация отклонена HTTP
  `401`: связанный PAM user отключён;
- inventory CPU/RAM/storage/bridge/templates не получен, потому что изменение
  user/token state выходит за рамки read-only аудита;
- секрет token не записан в репозиторий, audit artifacts или команды
  восстановления.

Для продолжения нужен включённый отдельный audit user, роль `PVEAuditor` на
`/`, действующий API token и сохранённый privilege separation. Не выдавать
этому token права на VM/LXC/storage/network modification.

## Ограничения

- Ничего не создавать, не удалять и не изменять.
- Не запускать update/upgrade/download.
- Не выводить private keys, passwords, API secrets и содержимое guest disks.
- До утверждения топологии не выполнять `pct create`, `qm create`, storage/NAT/
  bridge/firewall changes.

## Минимальный доступ

Предпочтительно выдать отдельный API token/user с ролью `PVEAuditor` на `/`.
Альтернатива — сообщить актуальный SSH port и пользователя, которому разрешены
только перечисленные ниже read-only команды. Token/пароль не записывать в Git.

## Host и версия

```sh
pveversion -v
hostnamectl
uname -a
uptime
```

## CPU и RAM

```sh
lscpu
free -h
swapon --show
```

## Диски и storage

```sh
lsblk -e 7 -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
df -hT
pvesm status
zpool status
zfs list
pvs
vgs
lvs
```

Команды для отсутствующего backend могут вернуть `command not found`; это не
ошибка аудита.

## Существующие guests

```sh
qm list
pct list
pvesh get /cluster/resources --type vm --output-format json-pretty
```

Не читать guest filesystems и не запускать/останавливать guests.

## Сеть

```sh
ip -br link
ip -br address
ip route show
bridge link show
bridge vlan show
cat /etc/network/interfaces
ss -lntup
nft list ruleset
sysctl net.ipv4.ip_forward
```

В отчёте нужны bridge names, VLAN-aware status, MTU, management network,
default gateway, свободная private subnet, public IP/NAT и возможность проброса
UDP для TURN. Полные firewall dumps не публиковать вне закрытой документации.

## Templates и ISO

```sh
pveam list local
pveam available --section system
find /var/lib/vz/template -maxdepth 2 -type f -printf '%p %s bytes\n'
```

Это только перечисление; `pveam download` не выполнять.

## API-вариант

После получения read-only token запрашиваются только GET endpoints:

```text
/api2/json/version
/api2/json/nodes
/api2/json/cluster/resources?type=vm
/api2/json/nodes/{node}/status
/api2/json/nodes/{node}/storage
/api2/json/nodes/{node}/network
/api2/json/nodes/{node}/qemu
/api2/json/nodes/{node}/lxc
```

## Выходной отчёт

1. Версия PVE и имя node.
2. CPU cores/threads и доступный RAM.
3. Storage type, total/free, snapshot/backup capabilities.
4. Уже занятые ресурсы VM/LXC.
5. Bridge/VLAN/NAT/public-IP схема.
6. Доступные Debian/Ubuntu templates.
7. Возможность Tailscale/WireGuard management overlay.
8. Возможность TURN UDP mapping.
9. Предлагаемая топология 5–8 logical nodes.

Только после отчёта составляется точный план CPU/RAM/disk/IP/ports и отдельно
запрашивается подтверждение на создание LXC/VM.
