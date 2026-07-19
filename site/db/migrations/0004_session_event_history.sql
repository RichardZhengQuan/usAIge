CREATE TABLE `relay_session_events` (
	`id` text PRIMARY KEY NOT NULL,
	`channel_id` text NOT NULL,
	`event_id` text NOT NULL,
	`kind` text NOT NULL,
	`session_title` text NOT NULL,
	`workspace_name` text NOT NULL,
	`occurred_at` text NOT NULL,
	`received_at` text NOT NULL,
	FOREIGN KEY (`channel_id`) REFERENCES `relay_channels`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `relay_session_events_channel_event_idx` ON `relay_session_events` (`channel_id`,`event_id`);
--> statement-breakpoint
CREATE INDEX `relay_session_events_channel_time_idx` ON `relay_session_events` (`channel_id`,`occurred_at` DESC);
