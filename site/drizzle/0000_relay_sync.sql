CREATE TABLE `relay_channels` (
	`id` text PRIMARY KEY NOT NULL,
	`mac_name` text NOT NULL,
	`upload_token_hash` text NOT NULL,
	`snapshot_json` text,
	`snapshot_hash` text,
	`snapshot_version` integer DEFAULT 0 NOT NULL,
	`created_at` text NOT NULL,
	`last_upload_at` text
);
--> statement-breakpoint
CREATE UNIQUE INDEX `relay_channels_upload_token_hash_unique` ON `relay_channels` (`upload_token_hash`);--> statement-breakpoint
CREATE TABLE `relay_devices` (
	`id` text PRIMARY KEY NOT NULL,
	`channel_id` text NOT NULL,
	`name` text NOT NULL,
	`read_token_hash` text NOT NULL,
	`apns_token` text,
	`apns_environment` text,
	`last_push_at` text,
	`created_at` text NOT NULL,
	`last_seen_at` text NOT NULL,
	FOREIGN KEY (`channel_id`) REFERENCES `relay_channels`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `relay_devices_read_token_hash_unique` ON `relay_devices` (`read_token_hash`);--> statement-breakpoint
CREATE INDEX `relay_devices_channel_idx` ON `relay_devices` (`channel_id`);--> statement-breakpoint
CREATE TABLE `relay_pairings` (
	`id` text PRIMARY KEY NOT NULL,
	`channel_id` text NOT NULL,
	`code_hash` text NOT NULL,
	`expires_at` text NOT NULL,
	`claimed_at` text,
	`failed_attempts` integer DEFAULT 0 NOT NULL,
	`created_at` text NOT NULL,
	FOREIGN KEY (`channel_id`) REFERENCES `relay_channels`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `relay_pairings_code_hash_unique` ON `relay_pairings` (`code_hash`);--> statement-breakpoint
CREATE TABLE `relay_rate_limits` (
	`key` text PRIMARY KEY NOT NULL,
	`count` integer NOT NULL,
	`window_started_at` text NOT NULL
);
