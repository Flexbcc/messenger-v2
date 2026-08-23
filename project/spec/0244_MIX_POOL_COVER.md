# 0244 — Bounded Mix Pool и Cover Scheduler v1

Mix Pool хранит cells только в памяти, ограничивает их количество и общий
объём, удаляет просроченные, назначает каждой cell независимый CSPRNG jitter и
перемешивает готовый batch перед отправкой. Медленный downstream не удерживает
admission lock.

Если downstream dispatch завершился ошибкой, текущая и ещё не отправленная
часть batch возвращается в pool до исходного expiry. Ошибка не превращается в
неявный ACK и не уничтожает real cell.

Cells, временно вынутые для dispatch, остаются учтёнными как in-flight в общих
лимитах количества и bytes. Поэтому параллельный admission не может заполнить
освободившееся место и заставить retry превысить RAM budget.

При заполнении реальные cells сначала вытесняют cover cells. Реальные cells не
вытесняются молча: admission возвращает `MixPoolFull`, после чего верхний слой
может reroute или применить backpressure.

Cover Scheduler создаёт CSPRNG dummy cells с jitter и жёстким скользящим
часовым budget без burst на границе часа. В adaptive mode рост real utilization
уменьшает частоту cover; overload или utilization >=95% временно прекращают
dummy traffic. Ошибка cover sink не останавливает data plane и видна в status.
Он не маркирует dummy внутри transport packet: различие существует только до
построения внешне неразличимой onion cell. Runtime wiring включается только
после reviewed provider, иначе случайные bytes не являются корректным cover.
