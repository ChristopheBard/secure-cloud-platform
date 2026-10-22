package auth

import (
	"errors"
	"net/http"
	"os"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/gin-gonic/gin"
)

type Claims struct {
	Username string `json:"username"`
	jwt.RegisteredClaims
}
var SECRET_KEY string = os.Getenv("SECRET_KEY")

func ValidateSession(c * gin.Context) (bool){
	cookie, err := c.Cookie("token")
	if err != nil {
		if err == http.ErrNoCookie {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "session expired, please login again"})
			return false
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "error occured while getting cookie"})
		return false
	}

	token, err := ValidateJWT(cookie)
	if err != nil {
		if errors.Is(err, jwt.ErrSignatureInvalid) {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "Unauthorized, signature invalid"})
			return false
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "error occured while validating token"})
	}

	if !token.Valid {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "Unauthorized, invalid token"})
		return false
	}
	return true
}

func GenerateJWT(userid string) (string ,error, time.Time) {
	// Declare the expiration time of the token
	// here, we have kept it as 5 minutes
	expirationTime := time.Now().Add(5 * time.Minute)
	// Create the JWT claims, which includes the username and expiry time
	claims := &Claims{
		Username: userid,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(expirationTime),
		},
	}

	// Declare the token with the algorithm used for signing, and the claims
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	// Create the JWT string
	tokenString, err := token.SignedString([]byte(SECRET_KEY))

	return tokenString, err, expirationTime
}


func ValidateJWT(token string) (jwt.Token, error){
	claims := &Claims{}
	tkn, err := jwt.ParseWithClaims(token, claims, func(token *jwt.Token) (interface{}, error) {
		return []byte(SECRET_KEY), nil
	})
	if tkn == nil { // jeton illisible : la v5 ne renvoie pas d'objet
		return jwt.Token{}, err
	}
	return *tkn, err
}

func RefreshToken(c * gin.Context) (bool,error,time.Time){

	token, err := c.Cookie("token")
	if err != nil {
		if err == http.ErrNoCookie {
			return true,nil,time.Time{}
		}
		return true,err,time.Time{}
	}

	claims := &Claims{}
	tkn, err := jwt.ParseWithClaims(token, claims, func(token *jwt.Token) (interface{}, error) {
		return []byte(SECRET_KEY), nil
	})
	if err != nil {
		if errors.Is(err, jwt.ErrSignatureInvalid) {
			return true,nil,time.Time{}
		}
		return false,err,time.Time{}
	}
	if !tkn.Valid || claims.ExpiresAt.Time.Sub(time.Now()) > 30*time.Second {
		return true,nil,claims.ExpiresAt.Time
	}
	return false,nil,claims.ExpiresAt.Time
}