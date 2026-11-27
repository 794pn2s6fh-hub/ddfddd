# Эксперимент: чтение App Bundles через MCMAppContainer

## Что изменено

- Добавлен `worse_query_app_bundle()` в `Erosion/Exploits/worse_query.m`.
- Контейнерный класс не захардкожен: он запрашивается у `MCMAppContainer +typeContainerClass` в `MobileContainerManager.framework`.
- Для поиска используется `container_query_set_identifiers()` с Bundle ID, а не `container_query_set_group_identifiers()`.
- Запрашивается корневой part (0), затем копируется sandbox token и проверяется фактический `open()` каталога `.app`.
- Если MCM не выдаёт результат, не возвращает token, возвращает другой root или `open()` отклонён, UI получает отдельную диагностику.
- В Apps добавлен read-only пункт `App Bundles (experimental)`. Метаданные `.app` по-прежнему берутся из InstallationProxy. При открытии `.app` или вложенной папки используется найденный Bundle ID и новый MCM probe.
- Остальные маршруты Worse Query/Bad Query не менялись.

## Почему выбран такой вариант

Обычный Erosion Worse Query использует MCM class 7 + group identifier + `Library/Caches` symlink/part traversal. Это не модель App Bundle container. В публичных заголовках `MCMAppContainer` существует как отдельный `MCMContainer` subclass с `+typeContainerClass`; FilzaSlop показывает отдельный setter `container_query_set_identifiers()` для обычных identifiers. Поэтому пробуется прямой lookup по Bundle ID без path traversal.

## Ограничение, известное заранее

README WQ Files (проект, использующий тот же Worse Query) указывает, что App Bundles доступны только на тех версиях iOS, где ОС разрешает открывать эти каталоги; в частности, в тестовой матрице автор указывает, что iOS 26 и iOS 27.0.1 не дают этот доступ. Это значит, что новый MCM query — исследовательская гипотеза, а не подтверждённый обход ограничения. Функция отличает отказ MCM, отсутствие sandbox token и последующий `open()` denial.

## Проверка на устройстве

1. Собрать и установить Erosion.
2. Открыть File Browser → Apps → App Bundles (experimental).
3. Убедиться, что InstallationProxy metadata перечислила приложения.
4. Открыть один `.app`.
5. При успехе должны появиться его файлы/папки (режим read-only).
6. При отказе прислать точный текст ошибки из экрана — особенно `class`, `POSIX`, `message`, `errno` и root path. Он покажет, на каком уровне блокируется доступ.

## Важная оговорка

В контейнерной среде здесь нет Xcode/iOS SDK и физического iOS-устройства. Поэтому я не могу выполнить iOS-сборку или подтвердить runtime-успех этого частного MCM API. Изменение — экспериментальный probe, не заявление о гарантированном доступе.
