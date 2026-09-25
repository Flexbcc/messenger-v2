# OUO Traffic Observer

Метаданный L4-транзит для локальных экспериментов с traffic correlation.
Он пересылает TCP-поток без завершения TLS и записывает только:

- время события;
- логические source/target;
- направление;
- размер фрагмента TCP-потока;
- длительность и суммарный объём соединения;
- тип сетевой ошибки без текста исключения.

Payload, HTTP path, UserID, ConversationID, MessageID, ключи и ciphertext в
журнал не записываются.

Запуск:

```sh
python3 observer.py --config example.json --output ./captures/run.jsonl
```

Для эксперимента endpoint следующего hop указывается как адрес listener
наблюдателя. `upstream_host/upstream_port` остаётся настоящим адресом hop.
Для каждого наблюдаемого ребра используется отдельный listener. TLS должен
завершаться на настоящих нодах, а не на Observer.

Это лабораторный измеритель, не production-компонент и не доверенная нода OUO.

## Изолированный Docker-режим

Observer добавляется к обычному локальному стенду отдельным compose-файлом:

```sh
docker compose -f docker-compose.yml -f docker-compose.observer.yml \
  --profile observer up -d traffic-observer
```

В наблюдаемом маршруте Relay endpoint временно указывается как
`ws://traffic-observer:18005/relay/ws` (для HTTP — тот же host/port). Observer
перешлёт поток настоящему `relay-node:8005`. Это осознанная лабораторная
настройка: без перенаправления endpoint Observer не находится на пути пакета и
ничего не видит.

Метаданные сохраняются в `data/traffic-observer/traffic.jsonl`. Контейнер
работает без root, capabilities и права записи куда-либо кроме каталога
captures. Один файл ограничен 128 MiB, сохраняются не более трёх предыдущих
ротаций. Таким образом лабораторный Observer не может бесконечно заполнять
диск. В основной compose-файл он не входит и без профиля не запускается.

Сводка наблюдаемых рёбер и временных характеристик:

```sh
python3 analyze.py ./captures/run.jsonl --output ./captures/summary.json
```

Отчёт намеренно не пытается объявить два потока одним сообщением. Для оценки
correlation будет использоваться отдельный ground-truth журнал генератора;
смешивание этих данных внутри Observer сделало бы эксперимент недостоверным.
