#include <sourcemod>
#include <neotokyo>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
    name = "NEOTOKYO° Temporary score saver",
    author = "soft as HELL +glub",
    description = "Saves score when player disconnects and restores it if player connects back before map change",
    version = "0.5.1",
    url = "https://github.com/glubsy"
};

Handle hDB, hRestartGame, hResetScoresTimer, hScoreDatabase, g_hForwardLoadedSavedScore;
bool bScoreLoaded[MAXPLAYERS+1],bResetScores, g_bHasJoinedATeam[MAXPLAYERS+1];

public void OnPluginStart()
{
hScoreDatabase = CreateConVar("nt_savescore_database", "nt_savescores", "Database filename for saving scores", FCVAR_PROTECTED);	

	hRestartGame = FindConVar("neo_restart_this");

	// Hook restart command
	if(hRestartGame != INVALID_HANDLE)
	{
		HookConVarChange(hRestartGame, RestartGame);
	}

	AddCommandListener(cmd_JoinTeam, "jointeam");

	HookEvent("game_round_start", event_RoundStart);

	g_hForwardLoadedSavedScore = CreateGlobalForward("OnSavedScoreLoaded", ET_Event, Param_Cell, Param_Cell);
	bResetScores = false;
}

public void OnConfigsExecuted()
{	
	// Create new database if it doesn't exist
	DB_init();

	// Clear it if we're reloading plugin or just started it
	DB_clear();
	
	bResetScores = false;
}

public void RestartGame(Handle convar, const char[] oldValue, const char[] newValue)
{
	if(StringToInt(newValue) == 0)
		return; // Not restarting

	if(hResetScoresTimer != INVALID_HANDLE)
		CloseHandle(hResetScoresTimer);

	float fTimer = StringToFloat(newValue);

	hResetScoresTimer = CreateTimer(fTimer - 0.1, ResetScoresNextRound);
}

public Action ResetScoresNextRound(Handle timer)
{
	bResetScores = true;

	hResetScoresTimer = INVALID_HANDLE;
}

public void OnClientPutInServer(int client)
{
	g_bHasJoinedATeam[client] = false;
}

public void OnClientDisconnect(int client)
{
	if(!bScoreLoaded[client] && !g_bHasJoinedATeam[client])
		return; // Never tried to load score

	DB_insertScore(client);

	bScoreLoaded[client] = false;
}

public Action cmd_JoinTeam(int client, const char[] command, int argc)
{ 
	char cmd[3];
	GetCmdArgString(cmd, sizeof(cmd));

	if(!IsValidClient(client))
		return;

	if(IsPlayerAlive(client))
		return; // Alive player switching team, should never happen when you just connect

	int team_current = GetClientTeam(client);
	int team_target = StringToInt(cmd);

	if(team_current == team_target && team_target != 0 && team_current != 0)
		return; // Trying to join same team

	// Score isn't loaded from DB yet
	if(!bScoreLoaded[client])
		DB_retrieveScore(client);
	
	g_bHasJoinedATeam[client] = true;
}

public Action event_RoundStart(Handle event, const char[] name, bool dontBroadcast)
{
	if(!bResetScores)
		return;
	
	bResetScores = false;
	
	DB_clear();
}

void DB_init()
{
	char error[255], buffer[50];

	GetConVarString(hScoreDatabase, buffer, sizeof(buffer));
	
	hDB = SQLite_UseDatabase(buffer, error, sizeof(error));
	
	if(hDB == INVALID_HANDLE)
		SetFailState("SQL error: %s", error);
	
	SQL_LockDatabase(hDB);

	SQL_FastQuery(hDB, "VACUUM");
	SQL_FastQuery(hDB, "CREATE TABLE IF NOT EXISTS nt_saved_score (steamID TEXT PRIMARY KEY, xp SMALLINT, deaths SMALLINT);");
	
	SQL_UnlockDatabase(hDB);
}

void DB_clear()
{
	SQL_LockDatabase(hDB);

	SQL_FastQuery(hDB, "DELETE FROM nt_saved_score;");

	SQL_UnlockDatabase(hDB);
}

void DB_insertScore(int client)
{
	if(!IsValidClient(client))
		return;

	char steamID[30], query[200];
	int xp, deaths;
	
	GetClientAuthId(client, AuthId_SteamID64, steamID, sizeof(steamID));

	xp = GetPlayerXP(client);
	deaths = GetPlayerDeaths(client);
	
	Format(query, sizeof(query), "INSERT OR REPLACE INTO nt_saved_score VALUES ('%s', %d, %d);", steamID, xp, deaths);
	
	SQL_FastQuery(hDB, query);
}

void DB_deleteScore(int client)
{
	if(!IsValidClient(client))
		return;

	char steamID[30], query[200];

	GetClientAuthId(client, AuthId_SteamID64, steamID, sizeof(steamID));

	Format(query, sizeof(query), "DELETE FROM nt_saved_score WHERE steamID = '%s';", steamID);

	SQL_FastQuery(hDB, query);
}

void DB_retrieveScore(int client)
{
	if(!IsValidClient(client))
		return;

	bScoreLoaded[client] = true; // At least we tried!

	char steamID[30], query[200];
	
	GetClientAuthId(client, AuthId_SteamID64, steamID, sizeof(steamID));

	Format(query, sizeof(query), "SELECT * FROM	nt_saved_score WHERE steamID = '%s';", steamID);

	SQL_TQuery(hDB, DB_retrieveScoreCallback, query, client);
}

public void DB_retrieveScoreCallback(Handle owner, Handle hndl, const char[] error, int client)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("SQL Error: %s", error);
		return;
	}

	if(!IsValidClient(client))
		return;

	if (SQL_GetRowCount(hndl) == 0)
		return;

	int xp = SQL_FetchInt(hndl, 1);
	int deaths = SQL_FetchInt(hndl, 2);

	if(xp != 0 || deaths != 0)
	{
		SetPlayerXP(client, xp);
		SetPlayerDeaths(client, deaths);
		UpdatePlayerRank(client);
	}

	PushOnLoadedSavedScoreForward(client, xp); //forwarding XP restored to other plugins

	PrintToChat(client, "[NT°] Saved score restored!");
	PrintToConsole(client, "[NT°] Saved score restored! XP: %d Deaths: %d", xp, deaths);

	// Remove score from DB after it has been loaded
	DB_deleteScore(client);
}


void PushOnLoadedSavedScoreForward(int client, int loadedscore)
{
	Call_StartForward(g_hForwardLoadedSavedScore);
	Call_PushCell(client);
	Call_PushCell(loadedscore);
	Call_Finish();
}
