/// Emergency lock severity — see product roadmap §4.
enum EmergencyLockLevel {
  soft,
  full,
  critical;

  String get label => switch (this) {
        EmergencyLockLevel.soft => 'Мягкая',
        EmergencyLockLevel.full => 'Полная',
        EmergencyLockLevel.critical => 'Критическая',
      };

  String get description => switch (this) {
        EmergencyLockLevel.soft => 'Завершить сеансы на других устройствах и выйти здесь.',
        EmergencyLockLevel.full =>
          'Мягкая + заблокировать новые входы, отключить уведомления, закрыть Private Mode.',
        EmergencyLockLevel.critical =>
          'Полная + стереть Secret Room, удалить локальные ключи, блокировка до восстановления.',
      };
}
