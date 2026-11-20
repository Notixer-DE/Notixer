use sea_orm_migration::prelude::*;

pub struct Migrator;
#[async_trait::async_trait]
impl MigratorTrait for Migrator {
    fn migrations() -> Vec<Box<dyn MigrationTrait>> {
        vec![
            Box::new(Initial),
            Box::new(AdminTables),
            Box::new(PairingCodes),
        ]
    }
}

struct Initial;
impl MigrationName for Initial {
    fn name(&self) -> &str {
        "m20261110_000001_sync"
    }
}
#[async_trait::async_trait]
impl MigrationTrait for Initial {
    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        manager
            .get_connection()
            .execute_unprepared(include_str!("../schema.sql"))
            .await?;
        Ok(())
    }
    async fn down(&self, _manager: &SchemaManager) -> Result<(), DbErr> {
        Err(DbErr::Custom(
            "Destructive rollback is deliberately disabled".into(),
        ))
    }
}

struct AdminTables;

impl MigrationName for AdminTables {
    fn name(&self) -> &str {
        "m20261118_000002_admin_tables"
    }
}

#[async_trait::async_trait]
impl MigrationTrait for AdminTables {
    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        manager
            .get_connection()
            .execute_unprepared(
                r#"
                CREATE TABLE admin_users (
                    username text PRIMARY KEY,
                    password_hash text NOT NULL
                );

                CREATE TABLE admin_sessions (
                    token text PRIMARY KEY,
                    username text NOT NULL REFERENCES admin_users(username) ON DELETE CASCADE,
                    expires_at timestamptz NOT NULL
                );

                CREATE INDEX admin_sessions_expires_at_idx ON admin_sessions(expires_at);
                "#,
            )
            .await?;
        Ok(())
    }

    async fn down(&self, _manager: &SchemaManager) -> Result<(), DbErr> {
        Err(DbErr::Custom(
            "Destructive rollback is deliberately disabled".into(),
        ))
    }
}

struct PairingCodes;

impl MigrationName for PairingCodes {
    fn name(&self) -> &str {
        "m20261120_000003_pairing_codes"
    }
}

#[async_trait::async_trait]
impl MigrationTrait for PairingCodes {
    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        manager
            .get_connection()
            .execute_unprepared(
                "CREATE TABLE pairing_codes (
                account_id uuid PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
                code_hash text NOT NULL UNIQUE,
                expires_at timestamptz NOT NULL
            )",
            )
            .await?;
        Ok(())
    }

    async fn down(&self, _manager: &SchemaManager) -> Result<(), DbErr> {
        Err(DbErr::Custom(
            "Destructive rollback is deliberately disabled".into(),
        ))
    }
}
