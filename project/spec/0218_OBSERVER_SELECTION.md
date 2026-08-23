# 0218 — Synthetic Challenge observer selection v1

Subject нода не выбирает observers. Детерминированный selection получает только
внешние входы:

- quorum-approved randomness seed;
- authority epoch;
- challenge type;
- subject NodeID;
- eligible observer set;
- authority-supplied diversity groups.

Subject исключается. Candidates ранжируются SHA-256 с domain separation.
Сначала выбирается максимум один observer из diversity group, затем при
необходимости заполняются оставшиеся позиции.

`diversity_group` нельзя брать из самодекларации ноды как доказанный факт. Он
должен поступать из проверенного Authority/Operator state. ASN/IP/geography
остаются вспомогательными сигналами.

Quorum-approved input, checkpoint chain и proposal-only scheduler определены в
`0236`; assignment/ACK/completion lifecycle — в `0219`, `0232`–`0235`.
Автоматическая cadence, threshold-VRF и penalties за невыполненное задание ещё
не реализованы.
