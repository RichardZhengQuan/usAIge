CREATE TABLE IF NOT EXISTS `relay_tool_pairings` (
	`id` text PRIMARY KEY NOT NULL,
	`channel_id` text NOT NULL,
	`code_hash` text NOT NULL,
	`expires_at` text NOT NULL,
	`claimed_at` text,
	`created_at` text NOT NULL,
	FOREIGN KEY (`channel_id`) REFERENCES `relay_channels`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS `relay_tool_pairings_code_hash_unique` ON `relay_tool_pairings` (`code_hash`);--> statement-breakpoint
CREATE TABLE IF NOT EXISTS `relay_remote_tools` (
	`id` text PRIMARY KEY NOT NULL,
	`channel_id` text NOT NULL,
	`name` text NOT NULL,
	`symbol_name` text NOT NULL,
	`website_url` text,
	`write_token_hash` text NOT NULL,
	`snapshot_json` text,
	`created_at` text NOT NULL,
	`last_upload_at` text,
	FOREIGN KEY (`channel_id`) REFERENCES `relay_channels`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS `relay_remote_tools_write_token_hash_unique` ON `relay_remote_tools` (`write_token_hash`);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS `relay_remote_tools_channel_idx` ON `relay_remote_tools` (`channel_id`);
