-- Copyright 2020 Wirepath Home Systems, LLC. All rights reserved.

AUTH_CODE_GRANT_VER = 15

require ('drivers-common-public.global.lib')
require ('drivers-common-public.global.url')
require ('drivers-common-public.global.timer')

pcall (require, 'drivers-common-public.global.make_short_link')

local oauth = {}

function oauth:new (tParams, initialRefreshToken)
	local o = {
		NAME = tParams.NAME,
		AUTHORIZATION = tParams.AUTHORIZATION,

		SHORT_LINK_AUTHORIZATION = tParams.SHORT_LINK_AUTHORIZATION,
		LINK_CHANGE_CALLBACK = tParams.LINK_CHANGE_CALLBACK,

		REDIRECT_URI = tParams.REDIRECT_URI,
		AUTH_ENDPOINT_URI = tParams.AUTH_ENDPOINT_URI,
		TOKEN_ENDPOINT_URI = tParams.TOKEN_ENDPOINT_URI,

		REDIRECT_DURATION = tParams.REDIRECT_DURATION,

		API_CLIENT_ID = tParams.API_CLIENT_ID,
		API_SECRET = tParams.API_SECRET,

		SCOPES = tParams.SCOPES,

		TOKEN_HEADERS = tParams.TOKEN_HEADERS,

		notifyHandler = {},
		Timer = {},
	}

	if (tParams.USE_BASIC_AUTH_HEADER) then
		o.BasicAuthHeader = 'Basic ' .. C4:Base64Encode (tParams.API_CLIENT_ID .. ':' .. tParams.API_SECRET)
	end

	setmetatable (o, self)
	self.__index = self

	local _timer = function (timer)
		if (initialRefreshToken == nil) then
			local persistStoreKey = C4:Hash ('SHA256', C4:GetDeviceID () .. o.API_CLIENT_ID, SHA_ENC_DEFAULTS)
			local encryptedToken = PersistGetValue (persistStoreKey)
			if (encryptedToken) then
				local encryptionKey = C4:GetDeviceID () .. o.API_SECRET .. o.API_CLIENT_ID
				local refreshToken, error = SaltedDecrypt (encryptionKey, encryptedToken)
				if (refreshToken) then
					initialRefreshToken = refreshToken
				end
			end
		end

		o:RefreshToken (nil, initialRefreshToken)
	end

	SetTimer (nil, ONE_SECOND, _timer)

	return o
end

function oauth:MakeState (contextInfo, extras, uriToCompletePage)
	--print ('MakeState', contextInfo, extras, uriToCompletePage)
	if (type (contextInfo) ~= 'table') then
		contextInfo = {}
	end

	local state = GetRandomString (50)

	local url = MakeURL (self.REDIRECT_URI .. 'state')

	local headers = {
		Authorization = self.AUTHORIZATION,
	}

	local data = {
		duration = self.REDIRECT_DURATION,
		clientId = self.API_CLIENT_ID,
		authEndpointURI = self.AUTH_ENDPOINT_URI,
		state = state,
		redirectURI = uriToCompletePage,
	}

	local context = {
		contextInfo = contextInfo,
		state = state,
		extras = extras
	}

	self:urlPost (url, data, headers, 'MakeStateResponse', context)
end

function oauth:MakeStateResponse (strError, responseCode, tHeaders, data, context, url)
	--print ('MakeStateResponse', strError, responseCode, tHeaders, data, context, url)
	if (strError) then
		dbg ('Error with MakeState', strError)
		return
	end

	local contextInfo = context.contextInfo

	if (responseCode == 200) then
		local state = context.state
		local extras = context.extras

		local nonce = data.nonce
		local expiresAt = data.expiresAt or (os.time () + self.REDIRECT_DURATION)

		local timeRemaining = expiresAt - os.time ()

		local _timedOut = function (timer)
			CancelTimer (self.Timer.CheckState)

			self:setLink ('')

			self:notify ('ActivationTimeOut', contextInfo)
		end

		self.Timer.GetCodeStatusExpired = SetTimer (self.Timer.GetCodeStatusExpired, timeRemaining * ONE_SECOND, _timedOut)

		local _timer = function (timer)
			self:CheckState (state, contextInfo, nonce)
		end
		self.Timer.CheckState = SetTimer (self.Timer.CheckState, 5 * ONE_SECOND, _timer, true)

		self:GetLinkCode (state, contextInfo, extras)
	end
end

function oauth:GetLinkCode (state, contextInfo, extras)
	--print ('GetLinkCode', state, contextInfo, extras)
	if (type (contextInfo) ~= 'table') then
		contextInfo = {}
	end

	local scope
	if (self.SCOPES) then
		if (type (self.SCOPES) == 'table') then
			scope = table.concat (self.SCOPES, ' ')
		elseif (type (self.SCOPES) == 'string') then
			scope = self.SCOPES
		end
	end

	local args = {
		client_id = self.API_CLIENT_ID,
		response_type = 'code',
		redirect_uri = self.REDIRECT_URI .. 'callback',
		state = state,
		scope = scope,
	}

	if (extras and type (extras) == 'table') then
		for k, v in pairs (extras) do
			args [k] = v
		end
	end

	local link = MakeURL (self.AUTH_ENDPOINT_URI, args)

	if (self.SHORT_LINK_AUTHORIZATION and MakeShortLink) then
		local _linkCallback = function (shortLink)
			self:setLink (shortLink, contextInfo)
		end
		MakeShortLink (link, _linkCallback, self.SHORT_LINK_AUTHORIZATION)
	else
		self:setLink (link, contextInfo)
	end

	self:notify ('LinkCodeReceived', contextInfo, link)
end

function oauth:CheckState (state, contextInfo, nonce)
	--print ('CheckState', state, contextInfo, nonce)
	if (type (contextInfo) ~= 'table') then
		contextInfo = {}
	end

	local url = MakeURL (self.REDIRECT_URI .. 'state', {state = state, nonce = nonce})

	self:urlGet (url, nil, 'CheckStateResponse', {state = state, contextInfo = contextInfo})
end

function oauth:CheckStateResponse (strError, responseCode, tHeaders, data, context, url)
	--print ('CheckStateResponse', strError, responseCode, tHeaders, data, context, url)
	if (strError) then
		dbg ('Error with CheckState:', strError)
		return
	end

	local contextInfo = context.contextInfo

	if (responseCode == 200 and data.code) then
		-- state exists and has been authorized
		CancelTimer (self.Timer.CheckState)
		CancelTimer (self.Timer.GetCodeStatusExpired)

		self:GetUserToken (data.code, contextInfo)

		self:notify ('LinkCodeConfirmed', contextInfo)

	elseif (responseCode == 204) then
		self:notify ('LinkCodeWaiting', contextInfo)

	elseif (responseCode == 401) then
		-- nonce value incorrect or missing for this state

		self:setLink ('')

		CancelTimer (self.Timer.CheckState)
		CancelTimer (self.Timer.GetCodeStatusExpired)

		self:notify ('LinkCodeError', contextInfo)

	elseif (responseCode == 403) then
		-- state exists and has been denied authorization by the service

		self:setLink ('')

		CancelTimer (self.Timer.CheckState)
		CancelTimer (self.Timer.GetCodeStatusExpired)

		self:notify ('LinkCodeDenied', contextInfo, data.error, data.error_description, data.error_uri)

	elseif (responseCode == 404) then
		-- state doesn't exist

		self:setLink ('')

		CancelTimer (self.Timer.CheckState)
		CancelTimer (self.Timer.GetCodeStatusExpired)

		self:notify ('LinkCodeExpired', contextInfo)
	end
end

function oauth:GetUserToken (code, contextInfo)
	--print ('GetUserToken', code, contextInfo)
	if (type (contextInfo) ~= 'table') then
		contextInfo = {}
	end

	if (code) then
		local args = {
			client_id = self.API_CLIENT_ID,
			client_secret = self.API_SECRET,
			grant_type = 'authorization_code',
			code = code,
			redirect_uri = self.REDIRECT_URI .. 'callback',
		}

		local url = self.TOKEN_ENDPOINT_URI

		local data = MakeURL (nil, args)

		local headers = {
			['Content-Type'] = 'application/x-www-form-urlencoded',
			['Authorization'] = self.BasicAuthHeader,
		}

		if (self.TOKEN_HEADERS and type (self.TOKEN_HEADERS == 'table')) then
			for k, v in pairs (self.TOKEN_HEADERS) do
				if (not (headers [k])) then
					headers [k] = v
				end
			end
		end

		self:urlPost (url, data, headers, 'GetTokenResponse', {contextInfo = contextInfo})
	end
end

function oauth:RefreshToken (contextInfo, newRefreshToken)
	--print ('RefreshToken')

	if (newRefreshToken) then
		self.REFRESH_TOKEN = newRefreshToken
	end

	if (self.REFRESH_TOKEN == nil) then
		return
	end

	if (type (contextInfo) ~= 'table') then
		contextInfo = {}
	end

	local args = {
		refresh_token = self.REFRESH_TOKEN,
		client_id = self.API_CLIENT_ID,
		client_secret = self.API_SECRET,
		grant_type = 'refresh_token',
	}

	local url = self.TOKEN_ENDPOINT_URI

	local data = MakeURL (nil, args)

	local headers = {
		['Content-Type'] = 'application/x-www-form-urlencoded',
		['Authorization'] = self.BasicAuthHeader,
	}

	if (self.TOKEN_HEADERS and type (self.TOKEN_HEADERS == 'table')) then
		for k, v in pairs (self.TOKEN_HEADERS) do
			if (not (headers [k])) then
				headers [k] = v
			end
		end
	end

	self:urlPost (url, data, headers, 'GetTokenResponse', {contextInfo = contextInfo})
end

function oauth:GetTokenResponse (strError, responseCode, tHeaders, data, context, url)
	--print ('GetTokenResponse', strError, responseCode, tHeaders, data, context, url)
	if (strError) then
		dbg ('Error with GetToken:', strError)
		local _timer = function (timer)
			self:RefreshToken ()
		end
		self.Timer.RefreshToken = SetTimer (self.Timer.RefreshToken, 30 * 1000, _timer)
		return
	end

	local contextInfo = context.contextInfo

	if (responseCode == 200) then
		self.ACCESS_TOKEN = data.access_token
		self.REFRESH_TOKEN = data.refresh_token or self.REFRESH_TOKEN

		local persistStoreKey = C4:Hash ('SHA256', C4:GetDeviceID () .. self.API_CLIENT_ID, SHA_ENC_DEFAULTS)

		local encryptionKey = C4:GetDeviceID () .. self.API_SECRET .. self.API_CLIENT_ID
		local encryptedToken = SaltedEncrypt (encryptionKey, self.REFRESH_TOKEN)

		PersistSetValue (persistStoreKey, encryptedToken)

		self.SCOPE = data.scope or self.SCOPE

		self.EXPIRES_IN = data.expires_in

		if (self.EXPIRES_IN and self.REFRESH_TOKEN) then
			local _timer = function (timer)
				self:RefreshToken ()
			end

			self.Timer.RefreshToken = SetTimer (self.Timer.RefreshToken, self.EXPIRES_IN * 950, _timer)
		end

		print ((self.NAME or 'OAuth') .. ': Access Token received, accessToken:' .. tostring (self.ACCESS_TOKEN ~= nil) .. ', refreshToken:' .. tostring (self.REFRESH_TOKEN ~= nil))

		self:setLink ('')

		self:notify ('AccessTokenGranted', contextInfo, self.ACCESS_TOKEN, self.REFRESH_TOKEN)

	elseif (responseCode >= 400 and responseCode < 500) then
		self.ACCESS_TOKEN = nil
		self.REFRESH_TOKEN = nil

		local persistStoreKey = C4:Hash ('SHA256', C4:GetDeviceID () .. self.API_CLIENT_ID, SHA_ENC_DEFAULTS)

		PersistDeleteValue (persistStoreKey)

		print ((self.NAME or 'OAuth') .. ': Access Token denied:', data.error, data.error_description, data.error_uri)

		self:setLink ('')

		self:notify ('AccessTokenDenied', contextInfo, data.error, data.error_description, data.error_uri)
	end
end

function oauth:setLink (link, contextInfo)
	if (self.LINK_CHANGE_CALLBACK and type (self.LINK_CHANGE_CALLBACK) == 'function') then
		local success, ret = pcall (self.LINK_CHANGE_CALLBACK, link, contextInfo)
		if (success == false) then
			print ((self.NAME or 'OAuth') .. ':LINK_CHANGE_CALLBACK Lua error: ', link, ret)
		end
	end
end

function oauth:notify (handler, ...)
	if (self.notifyHandler [handler] and type (self.notifyHandler [handler]) == 'function') then
		local success, ret = pcall (self.notifyHandler [handler], ...)
		if (success == false) then
			print ((self.NAME or 'OAuth') .. ':' .. handler .. ' Lua error: ', ret, ...)
		end
	end
end

function oauth:urlDo (method, url, data, headers, callback, context)
	local ticketHandler = function (strError, responseCode, tHeaders, data, context, url)
		local func = self [callback]
		local success, ret = pcall (func, self, strError, responseCode, tHeaders, data, context, url)
	end

	urlDo (method, url, data, headers, ticketHandler, context)
end

function oauth:urlGet (url, headers, callback, context)
	self:urlDo ('GET', url, data, headers, callback, context)
end

function oauth:urlPost (url, data, headers, callback, context)
	self:urlDo ('POST', url, data, headers, callback, context)
end

function oauth:urlPut (url, data, headers, callback, context)
	self:urlDo ('PUT', url, data, headers, callback, context)
end

function oauth:urlDelete (url, headers, callback, context)
	self:urlDo ('DELETE', url, data, headers, callback, context)
end

function oauth:urlCustom (url, method, data, headers, callback, context)
	self:urlDo (method, url, data, headers, callback, context)
end

return oauth
