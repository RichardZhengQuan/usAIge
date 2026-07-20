CREATE TABLE `app_feedback` (
	`id` text PRIMARY KEY NOT NULL,
	`content` text NOT NULL,
	`platform` text NOT NULL,
	`system_version` text NOT NULL,
	`architecture` text NOT NULL,
	`locale` text NOT NULL,
	`language` text NOT NULL,
	`app_version` text NOT NULL,
	`app_build` text NOT NULL,
	`app_bundle_identifier` text NOT NULL,
	`submitted_at` text NOT NULL,
	`received_at` text NOT NULL
);
--> statement-breakpoint
CREATE INDEX `app_feedback_received_at_idx` ON `app_feedback` (`received_at` DESC);
