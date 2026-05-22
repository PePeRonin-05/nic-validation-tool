# NIC Validation Tool

Нагрузочное тестирование 100G сетевых карт в режиме loopback.

---

## Запуск

```bash
./run.sh <тест> <хост> <порт1> <порт2> [<порт3> <порт4> ...] <длительность-сек>
```

```bash
./run.sh iperf 10.0.0.1 enp241s0f0np0 enp241s0f1np1 43200
./run.sh rdma  10.0.0.1 enp241s0f0np0 enp241s0f1np1 43200
./run.sh all   10.0.0.1 enp241s0f0np0 enp241s0f1np1 86400

# Две карты одновременно
./run.sh rdma  10.0.0.1 ens121f0np0 ens121f1np1 ens120f0np0 ens120f1np1 43200
```

---

## Тесты

| Тест | Инструмент | Порог PASS |
|---|---|---|
| `iperf` | iperf3 | ≥ 85 Gbps |
| `rdma` | ib_read_bw + ib_write_bw | ≥ 90 Gbps |
| `all` | оба последовательно | — |

---

## Структура проекта

```
nic-validation-tool/
├── run.sh
├── inventory/
│   └── group_vars/all.yml   ← настройки (пароль, MTU, пороги)
└── roles/
    ├── common/              ← IP, MTU, ARP
    ├── iperf_loopback/      ← тест iperf3
    ├── rdma_loopback/       ← тест RDMA
    ├── parse_results/       ← вывод результата
    ├── collect_logs/        ← сохранение логов
    ├── diagnostics/         ← статистика интерфейсов
    └── cleanup/             ← очистка после теста
```

Логи сохраняются в `local_logs/` после каждого запуска.
