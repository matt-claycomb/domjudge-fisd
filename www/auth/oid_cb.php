<?php
require_once('../configure.php');
require_once(LIBDIR . '/init.php');

setup_database_connection();

require_once(LIBWWWDIR . '/common.php');
require_once(LIBWWWDIR . '/auth.php');

// Where the user was trying to go, we'll redirect them back
session_start();


if (isset($_REQUEST['code'])) {
	try {
		do_login_oidc();
	} catch (OpenIDConnectClientException $exception) {
		if (!$_REQUEST['code']) {
			throw $exception;
		}
	}
} else {
	header("Location: ../");
	exit;
}

header("Location: /");
exit;
