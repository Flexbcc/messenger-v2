import json, re, sys

SPEC = "../../ouo-settings-spec.json"
OUT  = "../src/i18n/spec.i18n.json"

spec = json.load(open(SPEC))

SECTION_EN = {
    "profile": "Profile",
    "identity": "Phone, email & sign-in",
    "privacy": "Privacy",
    "security": "Security",
    "hidden_chats": "Hidden chats",
    "contacts": "Contacts & trust",
    "notifications": "Notifications",
    "messages": "Messages & chats",
    "media": "Media & files",
    "devices": "Devices",
    "node": "Node & network",
    "sync": "Synchronization",
    "storage_ownership": "Data storage & ownership",
    "backup": "Backups",
    "calls": "Calls",
    "appearance": "Appearance",
    "data": "Data & deletion",
    "developer": "Developer",
}

TITLE_EN = {
"profile.avatar":"Avatar","profile.display_name":"Display name","profile.username_enabled":"Use username","profile.username":"Username","profile.bio":"Profile description","profile.public_id":"Public ID","profile.qr":"Profile QR code","profile.language":"Interface language","profile.time_format":"Time format","profile.date_format":"Date format",
"identity.phone_enabled":"Link phone","identity.phone":"Phone","identity.phone_verified":"Phone verified","identity.phone_login":"Allow phone login","identity.phone_recovery":"Use phone for recovery","identity.email_enabled":"Link email","identity.email":"Email","identity.email_verified":"Email verified","identity.email_login":"Allow email login","identity.email_recovery":"Use email for recovery","identity.security_notifications":"Receive security notifications",
"privacy.phone_visibility":"Who sees phone","privacy.phone_visibility_list":"Selected users","privacy.phone_search":"Who can find by phone","privacy.email_visibility":"Who sees email","privacy.email_visibility_list":"Selected users","privacy.username_search":"Allow search by username","privacy.avatar_visibility":"Who sees avatar","privacy.last_seen":"Last seen","privacy.last_seen_list":"Exceptions","privacy.online_status":"Show online status","privacy.read_receipts":"Send read receipts","privacy.typing_status":"Show typing","privacy.voice_record_status":"Show voice recording","privacy.incoming_messages":"Who can message first","privacy.calls_from":"Who can call","privacy.calls_allowlist":"Allowlist","privacy.group_invites":"Who can add to groups","privacy.qr_only":"QR-only mode","privacy.qr_mode":"QR access type","privacy.qr_ttl_minutes":"QR lifetime, minutes","privacy.invisible_mode":"Invisible mode",
"security.pin_enabled":"Enable PIN","security.pin":"Primary PIN","security.pin_length":"PIN length","security.alphanumeric_password":"Allow alphanumeric code","security.autolock":"Auto-lock","security.lock_on_background":"Lock when backgrounded","security.lock_on_screen_off":"Lock when screen off","security.biometry":"Use biometrics","security.pin_attempt_policy":"Wrong PIN policy","security.wipe_enabled":"Wipe local data after failures","security.wipe_after":"Attempts before wipe","security.fake_pin_enabled":"Fake PIN","security.fake_pin":"Fake PIN","security.fake_profile_mode":"What fake PIN opens","security.fake_profile_chats":"Fake profile chats","security.distress_signal":"Send hidden distress signal","security.distress_contacts":"Distress signal recipients","security.recovery_key_enabled":"Create Recovery Key","security.recovery_key":"Recovery Key","security.require_pin_for_critical":"Require PIN for critical actions",
"hidden.enabled":"Enable hidden chats","hidden.open_method":"Open method","hidden.pin":"Hidden chats PIN","hidden.chat_list":"Hidden chats list","hidden.hide_from_search":"Hide from search","hidden.hide_notifications":"Hide notifications","hidden.hide_media":"Hide media from shared gallery","hidden.autolock":"Hidden section auto-lock",
"contacts.import_enabled":"Import phone book","contacts.hash_lookup":"Match by number hashes","contacts.auto_add_mutual":"Auto-add mutual contacts","contacts.trusted_enabled":"Use trusted users list","contacts.trusted_list":"Trusted users list","contacts.trust_levels_enabled":"Use trust levels","contacts.trust_levels":"Available trust levels","contacts.blocked_list":"Blocked users","contacts.key_change_warning":"Warn on key change","contacts.block_on_key_change":"Block sending on key change",
"notifications.enabled":"Enable notifications","notifications.preview":"Notification content","notifications.types":"Notification types","notifications.dnd_enabled":"Do not disturb","notifications.dnd_schedule":"Schedule","notifications.dnd_exceptions":"Exceptions","notifications.hidden_chat_policy":"Hidden chat notifications",
"messages.send_key":"Send message","messages.save_drafts":"Auto-save drafts","messages.confirm_delete":"Confirm deletion","messages.confirm_large_files":"Confirm large files","messages.large_file_mb":"Large file threshold, MB","messages.read_receipts_override":"Show read status locally","messages.auto_delete_enabled":"Auto-delete messages","messages.auto_delete_ttl":"Retention period","messages.link_preview":"Link preview",
"media.autoload_wifi":"Auto-download on Wi-Fi","media.autoload_mobile":"Auto-download on mobile","media.max_autoload_mb":"Max auto-download size, MB","media.image_quality":"Photo quality","media.video_quality":"Video quality","media.save_to_gallery":"Save to gallery","media.cache_limit_gb":"Cache limit, GB","media.auto_cleanup":"Auto cache cleanup","media.auto_cleanup_after":"Delete after",
"devices.current":"Current device","devices.list":"All devices","devices.add":"Add device","devices.require_approval":"Require new device approval","devices.approval_methods":"Approval methods","devices.history_sync_default":"History for new device","devices.hidden_access_default":"New devices access to hidden chats","devices.remote_wipe":"Allow remote wipe",
"node.mode":"Connection mode","node.current":"Current node","node.custom_enabled":"Use custom node","node.custom_address":"Custom node address","node.certificate_fingerprint":"Certificate fingerprint","node.allow_fallback":"Allow fallback to shared network","node.allow_relays":"Allow relay nodes","node.allow_service_nodes":"Allow service nodes","node.proxy_enabled":"Use proxy","node.proxy_type":"Proxy type","node.proxy_address":"Proxy address","node.mobile_data":"Allow mobile network","node.roaming":"Allow roaming",
"sync.enabled":"Enable synchronization","sync.types":"What to sync","sync.network":"Sync network","sync.history_depth":"History depth",
"storage.summary":"Data placement overview","storage.message_location":"Where messages are stored","storage.message_nodes":"Message storage nodes","storage.replication_factor":"Message copy count","storage.media_location":"Where media is stored","storage.s3_endpoint":"S3 endpoint","storage.s3_bucket":"S3 bucket","storage.s3_access_key":"S3 access key","storage.s3_secret_key":"S3 secret key","storage.media_ttl_enabled":"Delete media by TTL","storage.media_ttl":"Media TTL","storage.key_location":"Where keys are stored","storage.backup_location":"Where backups are stored","storage.access_devices":"Devices with data access","storage.access_nodes":"Nodes storing encrypted data","storage.last_sync":"Last synchronization","storage.last_backup":"Last backup","storage.integrity_check":"Verify data integrity","storage.route_audit":"Audit delivery route","storage.delete_local":"Delete local copies","storage.delete_remote":"Request deletion of remote copies",
"backup.enabled":"Enable backups","backup.schedule":"Frequency","backup.contents":"What to include","backup.encryption":"Encrypt backup","backup.password":"Backup password","backup.create_now":"Create backup now","backup.restore":"Restore from backup",
"calls.p2p":"Allow P2P","calls.force_relay":"Always use relay","calls.video":"Allow video","calls.quality":"Video quality","calls.noise_suppression":"Noise suppression","calls.echo_cancellation":"Echo cancellation","calls.data_saver":"Data saver",
"appearance.theme":"Theme","appearance.text_size":"Text size","appearance.compact":"Compact mode","appearance.animations":"Animations","appearance.reduce_motion":"Reduce motion","appearance.chat_bubbles":"Message style",
"data.export_profile":"Export profile","data.export_history":"Export history","data.export_contacts":"Export contacts","data.clear_cache":"Clear cache","data.clear_local":"Delete local data","data.delete_profile":"Delete profile","data.revoke_all_devices":"Revoke all devices",
"developer.enabled":"Developer mode","developer.logs":"Logs","developer.network_debug":"Network requests","developer.test_notifications":"Test notifications","developer.test_crypto":"Test encryption","developer.protocol_version":"Protocol version",
}

# enum token -> (ru, en)
E = {
"2":("2","2"),"3":("3","3"),"4":("4","4"),"5":("5","5"),"6":("6","6"),"8":("8","8"),"10":("10","10"),"12":("12","12"),"15":("15","15"),"20":("20","20"),
"12h":("12 часов","12-hour"),"24h":("24 часа","24-hour"),
"15m":("15 минут","15 min"),"30s":("30 секунд","30 sec"),"1m":("1 минута","1 min"),"5m":("5 минут","5 min"),"1h":("1 час","1 hour"),
"1d":("1 день","1 day"),"7d":("7 дней","7 days"),"30d":("30 дней","30 days"),"90d":("90 дней","90 days"),"1y":("1 год","1 year"),
"DD.MM.YYYY":("DD.MM.YYYY","DD.MM.YYYY"),"MM/DD/YYYY":("MM/DD/YYYY","MM/DD/YYYY"),"YYYY-MM-DD":("YYYY-MM-DD","YYYY-MM-DD"),
"add_device":("Добавление устройства","Add device"),"all":("Все","All"),"any":("Любая","Any"),"audio":("Аудио","Audio"),"auto":("Авто","Auto"),
"balanced":("Сбалансированное","Balanced"),"blocked":("Заблокирован","Blocked"),"bubbles":("Пузыри","Bubbles"),"button_only":("Только кнопка","Button only"),
"calculator_screen":("Экран калькулятора","Calculator screen"),"calls":("Звонки","Calls"),"change_node":("Смена ноды","Change node"),"community":("Сообщество","Community"),
"compact":("Компактно","Compact"),"compressed":("Сжатое","Compressed"),"contact":("Контакт","Contact"),"contact_requests":("Запросы в контакты","Contact requests"),
"contacts":("Контакты","Contacts"),"corporate_verified":("Корпоративно подтверждён","Corporate verified"),"ctrl_enter":("Ctrl+Enter","Ctrl+Enter"),
"daily":("Ежедневно","Daily"),"dark":("Тёмная","Dark"),"delete_profile":("Удаление профиля","Delete profile"),"delivery_errors":("Ошибки доставки","Delivery errors"),
"device_encrypted":("Зашифровано на устройстве","Device-encrypted"),"device_only":("Только устройство","Device only"),"device_secure_store":("Защищённое хранилище устройства","Device secure store"),
"direct":("Личные","Direct"),"documents":("Документы","Documents"),"drafts":("Черновики","Drafts"),"email":("Почта","Email"),"empty_profile":("Пустой профиль","Empty profile"),
"en":("Английский","English"),"enter":("Enter","Enter"),"everyone":("Все","Everyone"),"export":("Экспорт","Export"),"extra_large":("Очень крупный","Extra large"),
"favorites":("Избранное","Favorites"),"flat":("Плоский","Flat"),"folders":("Папки","Folders"),"from_now":("С текущего момента","From now"),"from_pairing":("С момента привязки","From pairing"),
"full":("Полное","Full"),"generic":("Обычное","Generic"),"gesture":("Жест","Gesture"),"groups":("Группы","Groups"),"hardware_keystore":("Аппаратное хранилище","Hardware keystore"),
"hidden":("Скрыто","Hidden"),"hidden_chats":("Скрытые чаты","Hidden chats"),"high":("Высокое","High"),"http":("HTTP","HTTP"),"immediately":("Немедленно","Immediately"),
"invites":("По приглашению","By invite"),"keys":("Ключи","Keys"),"large":("Крупный","Large"),"light":("Светлая","Light"),"local_file":("Локальный файл","Local file"),
"local_only":("Только локально","Local only"),"low":("Низкое","Low"),"manual":("Вручную","Manual"),"media":("Медиа","Media"),"mentions":("Упоминания","Mentions"),
"messages":("Сообщения","Messages"),"monthly":("Ежемесячно","Monthly"),"never":("Никогда","Never"),"nobody":("Никто","Nobody"),"node_errors":("Ошибки ноды","Node errors"),
"none":("Нет","None"),"normal":("Обычный","Normal"),"off":("Выкл","Off"),"original":("Оригинал","Original"),"permanent":("Постоянный","Permanent"),
"personal":("Личная","Personal"),"personal_node":("Личная нода","Personal node"),"personal_node_s3":("Личная нода + S3","Personal node + S3"),"photos":("Фото","Photos"),
"pin":("PIN","PIN"),"profile":("Профиль","Profile"),"push":("Push","Push"),"qr":("QR","QR"),"qr_verified":("Подтверждён по QR","QR verified"),
"recipient_cache":("Кэш получателя","Recipient cache"),"recovery_key":("Ключ восстановления","Recovery key"),"replicated_nodes":("Реплицированные ноды","Replicated nodes"),
"replies":("Ответы","Replies"),"ru":("Русский","Russian"),"safe_profile":("Безопасный профиль","Safe profile"),"secret_command":("Секретная команда","Secret command"),
"security":("Безопасность","Security"),"selected":("Выбранные","Selected"),"selected_chats":("Выбранные чаты","Selected chats"),"selected_node":("Выбранная нода","Selected node"),
"selected_s3":("Выбранный S3","Selected S3"),"sender_device":("Устройство отправителя","Sender device"),"sender_only":("Только отправитель","Sender only"),"settings":("Настройки","Settings"),
"single_use":("Одноразовый","Single use"),"small":("Мелкий","Small"),"socks5":("SOCKS5","SOCKS5"),"system":("Системная","System"),"temporary":("Временный","Temporary"),
"through_node":("Через ноду","Through node"),"trusted":("Доверенный","Trusted"),"trusted_device":("Доверенное устройство","Trusted device"),"unknown":("Неизвестный","Unknown"),
"unverified":("Не подтверждён","Unverified"),"videos":("Видео","Videos"),"view_keys":("Просмотр ключей","View keys"),"weekly":("Еженедельно","Weekly"),"wifi_only":("Только Wi-Fi","Wi-Fi only"),
}

# bespoke EN descriptions (non-templated)
DESC_EN = {
"profile.avatar":"User profile image. Stored as a reference to a local or remote encrypted media object.",
"profile.display_name":"Name shown to others and in the chat list. Not a unique identifier.",
"profile.username_enabled":"Enables a public username as an extra way to search for and add the user.",
"profile.username":"Unique public username. Used for search without phone or QR code.",
"profile.bio":"Short profile description visible to users according to privacy settings.",
"profile.public_id":"Immutable public profile identifier, generated automatically by the client.",
"profile.qr":"Opens the profile QR code for secure exchange of identifier and keys.",
"identity.phone_enabled":"Enables linking a phone number to the profile.",
"identity.phone":"Phone number in international E.164 format.",
"identity.phone_verified":"System flag for successful phone number verification.",
"identity.email_enabled":"Enables linking an email address to the profile.",
"identity.email":"Email address for login, recovery and notifications.",
"identity.email_verified":"System flag for successful email verification.",
"security.pin_enabled":"Enables local client lock with a PIN code.",
"security.pin":"Secret local PIN. Must not be stored in plaintext and is never sent to the server.",
"security.pin_attempt_policy":"Informational description of delays and protective actions on wrong PIN entry.",
"security.fake_pin_enabled":"Enables an alternative PIN that opens a safe or decoy profile.",
"security.fake_pin":"Alternative PIN, outwardly indistinguishable from the primary PIN.",
"security.recovery_key":"Secret recovery key for the profile and cryptographic data.",
"node.custom_address":"URL of the user's own node.",
"node.certificate_fingerprint":"Node TLS certificate fingerprint for verifying connection authenticity.",
"storage.message_location":"Determines the physical storage location of encrypted messages.",
"storage.media_location":"Determines the physical storage location of encrypted media files.",
"storage.key_location":"Determines where the client stores local cryptographic keys.",
"backup.password":"Separate encryption password for the backup.",
}

def norm(d):
    return re.sub(r"«[^»]*»","«X»", d)

def en_desc(setting, section):
    sid = setting["id"]
    if sid in DESC_EN:
        return DESC_EN[sid]
    t = TITLE_EN.get(sid, setting["title"])
    sec = SECTION_EN.get(section["id"], section["title"])
    n = norm(setting.get("description",""))
    if n == "Переключатель «X». Значение true включает функцию, false отключает.":
        return f"Toggle for «{t}». true enables the feature, false disables it."
    if n == "Выбор одного значения для параметра «X» из фиксированного списка допустимых вариантов.":
        return f"Selects one value for «{t}» from a fixed list of allowed options."
    if n == "Действие «X». Не хранит постоянное значение, а запускает отдельный сценарий.":
        return f"Action «{t}». Holds no persistent value; it triggers a separate flow."
    if n == "Выбор одного или нескольких значений для параметра «X». Хранится как массив уникальных значений.":
        return f"Selects one or more values for «{t}». Stored as an array of unique values."
    if n == "Информационное поле «X». Заполняется системой и не редактируется пользователем.":
        return f"Informational field «{t}». Filled by the system and not editable by the user."
    if n == "Числовое значение параметра «X». Клиент должен проверять минимальное и максимальное значение.":
        return f"Numeric value for «{t}». The client must validate the minimum and maximum."
    if n == "Секретное значение «X». Не отображается открыто, не логируется и хранится только в защищённом виде.":
        return f"Secret value «{t}». Never shown openly, never logged, stored only in protected form."
    if n.startswith("Управляемый список «X». Каждый элемент имеет собственный идентификатор и тип"):
        it = setting.get("item_type","item")
        return f"Managed list «{t}». Each item has its own identifier and type {it}."
    if n == "Текстовое значение параметра «X» в разделе «X».":
        return f"Text value for «{t}» in the «{sec}» section."
    return None  # uncovered

out = {"sections": {}, "settings": {}, "enums": {}}
for sid,en in SECTION_EN.items():
    out["sections"][sid] = {"en": en}

uncovered = []
for section in spec["sections"]:
    for x in section["settings"]:
        sid = x["id"]
        ttl = TITLE_EN.get(sid)
        if ttl is None:
            uncovered.append(("title", sid))
            ttl = x["title"]
        d = en_desc(x, section)
        if d is None:
            uncovered.append(("desc", sid, x.get("description","")[:60]))
            d = x.get("description","")
        out["settings"][sid] = {"title": {"en": ttl}, "description": {"en": d}}

for tok,(ru,en) in E.items():
    out["enums"][tok] = {"ru": ru, "en": en}

# check all enum tokens present
missing_enums = set()
for section in spec["sections"]:
    for x in section["settings"]:
        for o in x.get("options",[]) or []:
            k = o if isinstance(o,str) else json.dumps(o)
            if k not in out["enums"]:
                missing_enums.add(k)

json.dump(out, open(OUT,"w",encoding="utf-8"), ensure_ascii=False, indent=2)
print("settings:",len(out["settings"]),"sections:",len(out["sections"]),"enums:",len(out["enums"]))
print("UNCOVERED:",uncovered)
print("MISSING ENUMS:",missing_enums)
