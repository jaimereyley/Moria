-- Recover gets your files out of a Moria vault without Moria, using only tools built into macOS.
-- files/ holds one Apple Encrypted Archive per file or folder, recording its path. key.aea holds the key they're
-- encrypted with, itself encrypted with your password as stretched by the PBKDF2 in key.kdf. openssl stretches the
-- password, aea decrypts the key with it, and aa extracts each archive with the key.

on run
	set vault to POSIX path of ((path to me as text) & "::")
	set vaultName to do shell script "basename " & quoted form of vault & " .moria"
	set reply to display dialog "Enter the password for “" & vaultName & "”." default answer "" with hidden answer with title "Recover" buttons {"Cancel", "Recover"} default button "Recover"
	set destination to POSIX path of (choose folder with prompt "Choose where to put “" & vaultName & "”." default location (path to desktop)) & vaultName
	try
		set recovered to recover(vault, text returned of reply, destination)
		do shell script "open " & quoted form of destination
		display dialog "Recovered " & recovered & " items into “" & destination & "”." with title "Recover" buttons {"OK"} default button "OK"
	on error errorMessage
		display alert "Couldn't recover “" & vaultName & "”" message errorMessage as critical
	end try
end run

-- Decrypts every archive in `vault` into the new folder `destination`, returning how many there were.
on recover(vault, pass, destination)
	set secret to do shell script "read kdf rounds salt < " & quoted form of (vault & "key.kdf") & " && printf %s " & quoted form of pass & " | /usr/bin/openssl enc -aes-256-cbc -pbkdf2 -md sha256 -iter \"$rounds\" -S \"$salt\" -pass stdin -P | /usr/bin/sed -n 's/^key=//p'"
	set vaultKey to do shell script "/usr/bin/aea decrypt -i " & quoted form of (vault & "key.aea") & " -o /dev/stdout -password-value " & quoted form of secret & " 2>/dev/null | /usr/bin/base64"
	if vaultKey is "" then error "That password doesn't open this vault."
	do shell script "/bin/mkdir " & quoted form of destination
	do shell script "cd " & quoted form of (vault & "files") & " && for f in *.aea; do /usr/bin/aa extract -i \"$f\" -d " & quoted form of destination & " -key-value base64:" & vaultKey & " || exit 1; done; ls | grep -c '[.]aea$'"
end recover
