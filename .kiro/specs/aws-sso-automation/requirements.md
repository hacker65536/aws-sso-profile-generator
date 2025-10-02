# Requirements Document

## Introduction

AWS SSO設定管理ツールは、AWS Single Sign-On (SSO) の設定を段階的に確認・作成・管理するためのBashスクリプト群です。このツールは、AWS Organizations + IAM Identity Center（旧AWS SSO）を利用するクラウドエンジニアの日常的な設定管理作業を効率化し、ヒューマンエラーを削減することを目的としています。

### 対象ユーザー

- **クラウドエンジニア**: AWS環境の運用・管理を担当する技術者
- **システム管理者**: AWS SSO設定の管理・監督を行う管理者
- **開発者**: AWS CLIを使用してAWSリソースにアクセスする開発者

### 技術要件

- **Bash**: バージョン4系以上（連想配列機能を使用）
- **AWS CLI**: v2.0.0以上
- **jq**: JSON処理用
- **column**: 表示整形用
- **OS**: macOS、Linux（Ubuntu、CentOS、RHEL等）をサポート

## Requirements

### Requirement 1

**User Story:** As a cloud engineer, I want to verify that all required tools are installed and properly configured, so that I can ensure the AWS SSO management scripts will work correctly.

#### Acceptance Criteria

1. WHEN I run the tool check script THEN the system SHALL verify the presence of bash version 4 or higher
2. WHEN I run the tool check script THEN the system SHALL verify the presence of AWS CLI v2
3. WHEN I run the tool check script THEN the system SHALL verify the presence of jq command
4. WHEN I run the tool check script THEN the system SHALL verify the presence of column command
5. IF any required tool is missing THEN the system SHALL provide clear installation instructions

### Requirement 2

**User Story:** As a cloud engineer, I want to check my AWS configuration files and get a summary of my current setup, so that I can understand my existing SSO configuration without reading through lengthy config files.

#### Acceptance Criteria

1. WHEN I run the AWS config check script THEN the system SHALL locate the AWS config file (default or custom path)
2. WHEN the config file exists THEN the system SHALL display a concise summary including SSO session count, profile count, and managed profile count
3. WHEN displaying the summary THEN the system SHALL list all SSO session names
4. WHEN displaying the summary THEN the system SHALL list all managed profile names
5. IF the config file does not exist THEN the system SHALL provide guidance on creating one

### Requirement 3

**User Story:** As a cloud engineer, I want to verify my SSO session configuration and check the current session status, so that I can ensure my SSO setup is correct and my session is active.

#### Acceptance Criteria

1. WHEN I run the SSO config check script THEN the system SHALL verify the presence of required SSO session configuration parameters
2. WHEN checking SSO configuration THEN the system SHALL validate sso_region, sso_start_url, and sso_registration_scopes settings
3. WHEN checking session status THEN the system SHALL search for SSO cache files and determine session validity
4. WHEN a valid session exists THEN the system SHALL display the session expiration time in local timezone
5. IF the session is expired or invalid THEN the system SHALL provide clear guidance on re-authentication

### Requirement 4

**User Story:** As a cloud engineer, I want to manage SSO profiles through an interactive interface, so that I can create, update, and view profiles without manually editing configuration files.

#### Acceptance Criteria

1. WHEN I run the profile management script THEN the system SHALL provide options to create, check, list, or update profiles
2. WHEN creating a new profile THEN the system SHALL prompt for all required parameters interactively
3. WHEN creating a profile THEN the system SHALL use standardized comment markers to identify managed profiles
4. WHEN listing profiles THEN the system SHALL display profiles in a formatted table using the column command
5. WHEN updating a profile THEN the system SHALL safely replace the existing profile configuration
6. IF a profile name already exists THEN the system SHALL detect the duplicate and provide appropriate options

### Requirement 5

**User Story:** As a cloud engineer, I want to automatically generate SSO profiles for all available accounts and roles, so that I can quickly set up access to multiple AWS accounts without manual configuration.

#### Acceptance Criteria

1. WHEN I run the profile generation script THEN the system SHALL use AWS CLI SSO commands to discover available accounts and roles
2. WHEN generating profiles THEN the system SHALL create profiles following the naming convention: {prefix}-{account-name}-{account-id}-{role-name}
3. WHEN generating profiles THEN the system SHALL provide options for account name normalization (full or minimal)
4. WHEN profiles are generated THEN the system SHALL use the same comment-based management system as manual profile creation
5. IF duplicate profiles exist THEN the system SHALL handle them appropriately based on user preference

### Requirement 6

**User Story:** As a cloud engineer, I want a unified main script that orchestrates all setup steps, so that I can run a complete AWS SSO setup process with a single command.

#### Acceptance Criteria

1. WHEN I run the main setup script THEN the system SHALL execute all individual scripts in the correct sequence
2. WHEN running the setup THEN the system SHALL first check for required tools
3. WHEN running the setup THEN the system SHALL check AWS configuration files
4. WHEN running the setup THEN the system SHALL verify SSO configuration and session status
5. WHEN running the setup THEN the system SHALL provide options for profile management
6. IF any step fails THEN the system SHALL provide clear error messages and stop execution

### Requirement 7

**User Story:** As a developer, I want all scripts to follow consistent design principles and coding standards, so that the tool suite is maintainable and reliable.

#### Acceptance Criteria

1. WHEN implementing any script THEN the system SHALL use unified UI, logging, and error handling patterns
2. WHEN displaying output THEN the system SHALL use consistent color coding and formatting
3. WHEN handling errors THEN the system SHALL use `set -euo pipefail` for reliable error detection
4. WHEN processing files THEN the system SHALL create backups before making changes
5. WHEN dealing with sensitive information THEN the system SHALL never display access tokens or credentials