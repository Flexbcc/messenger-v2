import 'package:flutter/material.dart';

import 'settings_catalog.dart';

/// Thematic grouping of catalog sections for settings navigation.
class SettingsBlock {
  const SettingsBlock({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.sectionIds,
  });

  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final List<String> sectionIds;

  int settingCount(SettingsCatalog catalog) {
    var n = 0;
    for (final sid in sectionIds) {
      n += catalog.sectionById(sid)?.settings.length ?? 0;
    }
    return n;
  }

  List<CatalogSection> sections(SettingsCatalog catalog) {
    return [
      for (final sid in sectionIds)
        if (catalog.sectionById(sid) != null) catalog.sectionById(sid)!,
    ];
  }
}

/// Full thematic map (for deep links / diagnostics). Prefer [kHubSettingsBlocks] on main hub.
const kSettingsBlocks = <SettingsBlock>[
  SettingsBlock(
    id: 'account',
    title: 'Профиль и вход',
    subtitle: 'Имя, username, телефон, почта',
    icon: Icons.person_outline,
    sectionIds: ['profile', 'identity'],
  ),
  SettingsBlock(
    id: 'privacy',
    title: 'Приватность и защита',
    subtitle: 'Видимость, PIN, скрытые чаты',
    icon: Icons.shield_outlined,
    sectionIds: ['privacy', 'security', 'hidden_chats'],
  ),
  SettingsBlock(
    id: 'communication',
    title: 'Общение',
    subtitle: 'Контакты, уведомления, сообщения, звонки',
    icon: Icons.chat_bubble_outline,
    sectionIds: ['contacts', 'notifications', 'messages', 'calls'],
  ),
  SettingsBlock(
    id: 'media_data',
    title: 'Медиа и данные',
    subtitle: 'Автозагрузка, кэш, экспорт, удаление',
    icon: Icons.perm_media_outlined,
    sectionIds: ['media', 'data', 'backup'],
  ),
  SettingsBlock(
    id: 'network',
    title: 'Сеть и синхронизация',
    subtitle: 'Нода, sync, устройства, хранение',
    icon: Icons.hub_outlined,
    sectionIds: ['devices', 'node', 'sync', 'storage_ownership'],
  ),
  SettingsBlock(
    id: 'interface',
    title: 'Интерфейс',
    subtitle: 'Тема, размер текста, анимации',
    icon: Icons.palette_outlined,
    sectionIds: ['appearance'],
  ),
  SettingsBlock(
    id: 'developer',
    title: 'Разработчик',
    subtitle: 'Логи, отладка, протокол',
    icon: Icons.code_outlined,
    sectionIds: ['developer'],
  ),
];

/// Sections shown on the main Settings hub — no duplicates of dedicated screens.
/// Profile/identity → ProfileScreen; appearance → AppearanceScreen; etc.
const kHubSettingsBlocks = <SettingsBlock>[
  SettingsBlock(
    id: 'visibility',
    title: 'Кто меня видит',
    subtitle: 'Поиск, онлайн, галочки, приглашения',
    icon: Icons.visibility_outlined,
    sectionIds: ['privacy'],
  ),
  SettingsBlock(
    id: 'messages_hub',
    title: 'Сообщения',
    subtitle: 'Отправка, черновики, превью ссылок',
    icon: Icons.chat_bubble_outline,
    sectionIds: ['messages'],
  ),
  SettingsBlock(
    id: 'media_hub',
    title: 'Медиа (каталог)',
    subtitle: 'Лимиты и качество; автозагрузка — в «Данные»',
    icon: Icons.perm_media_outlined,
    sectionIds: ['media'],
  ),
];

SettingsBlock? settingsBlockById(String id) {
  for (final b in [...kHubSettingsBlocks, ...kSettingsBlocks]) {
    if (b.id == id) return b;
  }
  return null;
}
