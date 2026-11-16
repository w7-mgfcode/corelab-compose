<?php
/**
 * Plugin Name: corelab SMTP
 * Description: WordPress sends every mail through the internal Postfix container (postfix:25).
 *
 * Relay authentication lives in Postfix, not here; the internal hop is unencrypted SMTP
 * on the internal "mail" Docker network.
 */

defined( 'ABSPATH' ) || exit;

add_action( 'phpmailer_init', function ( $phpmailer ) {
	$phpmailer->isSMTP();
	$phpmailer->Host        = 'postfix';
	$phpmailer->Port        = 25;
	$phpmailer->SMTPAuth    = false;
	$phpmailer->SMTPAutoTLS = false;
} );
